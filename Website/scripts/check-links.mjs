import { readdir, readFile, access } from 'node:fs/promises';
import { join, resolve, extname } from 'node:path';
const root = resolve('dist');
async function files(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  return (await Promise.all(entries.map(entry => entry.isDirectory() ? files(join(dir, entry.name)) : join(dir, entry.name)))).flat();
}
const errors = [];
for (const file of (await files(root)).filter(file => extname(file) === '.html')) {
  const html = await readFile(file, 'utf8');
  for (const match of html.matchAll(/(?:href|src|poster)="([^" ]+)"/g)) {
    const href = match[1];
    if (/^(?:https?:|mailto:|data:)/.test(href)) continue;
    const url = new URL(href, 'https://local.test/' + file.slice(root.length + 1));
    let target = join(root, decodeURIComponent(url.pathname));
    if (url.pathname.endsWith('/')) target = join(target, 'index.html');
    try {
      await access(target);
      if (url.hash && extname(target) === '.html') {
        const content = await readFile(target, 'utf8');
        if (!content.includes(`id="${decodeURIComponent(url.hash.slice(1))}"`)) throw new Error('锚点不存在');
      }
    } catch (error) { errors.push(`${file.slice(root.length + 1)} → ${href}: ${error.message}`); }
  }
}
if (errors.length) throw new Error('站内链接或资源缺失：\n' + errors.join('\n'));
console.log('站内路由、锚点、图片和视频资源检查通过。');
