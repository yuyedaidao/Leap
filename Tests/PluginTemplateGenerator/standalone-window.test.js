'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { session } = require('../PluginSDK/session.cjs');
const directory = path.resolve(__dirname, '../../Examples/Plugins/StandaloneWindow');

test('独立窗口入口正常调用、拒绝未知命令并恢复', async t => {
  const process = session(path.join(directory, 'main.js'), 'standalone-window.run');
  t.after(() => process.close());
  assert.equal((await process.call('invoke')).value, '你好，这是独立窗口中的脚本返回结果！');
  assert.match((await process.call('invoke', '', undefined, 'unknown')).error, /未知命令/);
  assert.equal((await process.call('invoke')).value, '你好，这是独立窗口中的脚本返回结果！');
  assert.match(process.stderr, /收到网页调用/);
});

test('网页等待期间禁用按钮，成功或失败均恢复按钮', async () => {
  const source = fs.readFileSync(path.join(directory, 'index.html'), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
  for (const fail of [false, true]) {
    let click;
    let finish;
    const button = { disabled: false, addEventListener: (_, handler) => { click = handler; } };
    const result = { textContent: '' };
    const pending = new Promise((resolve, reject) => { finish = () => fail ? reject(new Error('测试失败')) : resolve('问候'); });
    vm.runInNewContext(source, {
      document: { querySelector: id => id === '#invoke' ? button : result },
      window: { leap: { invoke: (commandID, query) => {
        assert.equal(commandID, 'standalone-window.run');
        assert.equal(query, '');
        return pending;
      } } }, Error, console: { error() {} },
    });
    const invocation = click();
    assert.equal(button.disabled, true);
    finish();
    await invocation;
    assert.equal(button.disabled, false);
    assert.equal(result.textContent, fail ? '调用失败：测试失败' : '问候');
  }
});
