import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
const target = new URL('../public/reference/', import.meta.url);
await mkdir(target, { recursive: true });
await cp(new URL('../../Examples/', import.meta.url), new URL('Examples/', target), { recursive: true });
await mkdir(new URL('Docs/', target), { recursive: true });
await cp(new URL('../../Docs/PluginSDKValidation.md', import.meta.url), new URL('Docs/PluginSDKValidation.md', target));
console.log('已同步开发文档引用的仓库示例。');
// 只改发布路径，不维护第二份开发文档。
const source = await readFile(new URL('../../Docs/PluginDevelopment.md', import.meta.url), 'utf8');
const output = new URL('../src/generated/', import.meta.url);
await mkdir(output, { recursive: true });
await writeFile(new URL('PluginDevelopment.md', output), source
  .replaceAll('../Examples/', '/reference/Examples/')
  .replaceAll('(PluginSDKValidation.md)', '(/reference/Docs/PluginSDKValidation.md)'));
