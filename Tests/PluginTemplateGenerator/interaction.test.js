'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { generate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/main');
const { validate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/validation');

test('JS/Python列表模板查询和选择使用不同协议且校验条目', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapListTemplate-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const runtime of ['javascript', 'python']) {
    const directory = path.join(root, runtime);
    fs.mkdirSync(directory);
    generate({ directory, name: '列表', version: '1.0.0', runtime, interaction: 'list' });
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8'));
    assert.equal(manifest.minimumHostVersion, '1.1.0');
    assert.equal(manifest.commands[0].mode, 'interactive');
    assert.equal(manifest.commands[0].presentation, 'list');
    assert.equal(manifest.webEntry, undefined);
    const executable = runtime === 'javascript' ? process.execPath
      : path.resolve('Resources/Leap/Runtimes/python-3.14.7/Versions/3.14/bin/python3.14');
    const call = (method, query, itemID) => {
      const request = { jsonrpc: '2.0', id: 'list-test', method,
        params: { commandID: manifest.commands[0].id, query, itemID } };
      const run = spawnSync(executable, [path.join(directory, manifest.entry)], {
        input: JSON.stringify(request) + '\n', encoding: 'utf8', timeout: 3000,
      });
      assert.equal(run.status, 0, run.stderr);
      const response = JSON.parse(run.stdout);
      assert.equal(response.id, request.id);
      return response;
    };
    assert.deepEqual(JSON.parse(call('leap.query', '').result), { items: [] });
    const result = JSON.parse(call('leap.query', 'Hello').result);
    assert.equal(result.items[0].title, 'HELLO');
    assert.equal(result.items[1].title, 'hello');
    assert.equal(call('leap.select', 'Hello', 'upper').result, 'HELLO');
    assert.equal(call('leap.select', 'Hello', 'unknown').error.code, -32602);
    assert.equal(call('leap.invoke', 'Hello').error.code, -32602);
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
