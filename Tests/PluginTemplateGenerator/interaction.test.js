'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { session } = require('../PluginSDK/session.cjs');
const { generate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/main');
const { validate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/validation');

test('JS/Python列表模板查询和选择使用不同协议且校验条目', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapListTemplate-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const runtime of ['javascript', 'python']) {
    const directory = path.join(root, runtime);
    fs.mkdirSync(directory);
    generate({ directory, name: '列表', version: '1.0.0', runtime, interaction: 'list' });
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8'));
    assert.equal(manifest.minimumHostVersion, undefined);
    assert.equal(manifest.commands[0].mode, 'interactive');
    assert.equal(manifest.commands[0].presentation, 'list');
    assert.equal(manifest.webEntry, undefined);
    const plugin = session(path.join(directory, manifest.entry), manifest.commands[0].id, runtime);
    try {
      assert.deepEqual((await plugin.call('input', '')).items, []);
      const result = await plugin.call('input', 'Hello');
      assert.equal(result.items[0].title, 'HELLO');
      assert.equal(result.items[1].title, 'hello');
      assert.equal((await plugin.call('select', 'Hello', 'upper')).value, 'HELLO');
      assert.match((await plugin.call('select', 'Hello', 'unknown')).error, /失效/);
      assert.match((await plugin.call('invoke', 'Hello')).error, /动作/);
    } finally { await plugin.close(); }
  }
});

test('交互方式决定网页，Shell拒绝列表和网页', () => {
  const input = { directory: '/tmp/plugin', name: '插件', version: '1.0.0', runtime: 'javascript', width: 800, height: 600 };
  assert.equal(validate({ ...input, interaction: 'web' }).withUI, true);
  assert.equal(validate({ ...input, interaction: 'action' }).withUI, false);
  assert.throws(() => validate({ ...input, interaction: 'unknown' }), /交互/);
  for (const interaction of ['list', 'web']) {
    assert.throws(() => validate({ ...input, runtime: 'shell', interaction }), /直接执行/);
  }
});
