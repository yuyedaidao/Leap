import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateRelease } from '../scripts/release.mjs';
const preview = { version: '1.2.0', minimumMacOS: '26.0', architecture: 'arm64', downloadURL: null, sizeBytes: null, sha256: null };
const release = { ...preview, downloadURL: 'https://download.leap-app.cn/releases/1.2.0/Leap.dmg', sizeBytes: 2000000, sha256: 'a'.repeat(64) };
const production = { production: true, siteURL: 'https://www.leap-app.cn', icpNumber: '鲁ICP备12345678号-1' };
test('官网版本与应用发布版本一致', () => {
  const project = readFileSync(new URL('../../Project.swift', import.meta.url), 'utf8');
  const metadata = JSON.parse(readFileSync(new URL('../release.json', import.meta.url), 'utf8'));
  assert.equal(metadata.version, project.match(/"CFBundleShortVersionString": "([^"]+)"/)[1]);
});
test('预览允许无安装包，正式构建拒绝', () => {
  assert.equal(validateRelease(preview), preview);
  assert.throws(() => validateRelease(preview, production), /downloadURL/);
});
test('正式配置和完整发行数据通过', () => assert.equal(validateRelease(release, production), release));
test('元数据边界和不完整下载被拒绝', () => {
  for (const [key, value] of [['version', '1.2'], ['minimumMacOS', '14.0'], ['architecture', 'x86_64'], ['sizeBytes', 0], ['sizeBytes', 1.5], ['sha256', 'ABC'], ['downloadURL', 'http://download.leap-app.cn/a'], ['downloadURL', 'javascript:alert(1)'], ['downloadURL', 'https://user:pass@download.leap-app.cn/a'], ['downloadURL', 'https://localhost/a']]) {
    assert.throws(() => validateRelease({ ...release, [key]: value }), Error, key);
  }
  assert.throws(() => validateRelease({ ...preview, sha256: 'a'.repeat(64) }), /未开放/);
});
test('正式站点必须使用 HTTPS 根域名和已备案信息', () => {
  for (const siteURL of [undefined, 'http://www.leap-app.cn', 'https://example.com', 'https://www.leap-app.cn/sub', 'https://www.leap-app.cn/?a=1']) {
    assert.throws(() => validateRelease(release, { ...production, siteURL }), /SITE_URL/);
  }
  for (const icpNumber of [undefined, '', '待备案']) assert.throws(() => validateRelease(release, { ...production, icpNumber }), /ICP_NUMBER/);
});
