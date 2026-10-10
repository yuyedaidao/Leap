'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('真实注入脚本支持迟订阅、输入/提交/退出和移除监听', async () => {
  const script = fs.readFileSync('Resources/Leap/PluginSDK/host-api.js', 'utf8') + '\n' + fs.readFileSync('Resources/Leap/PluginSDK/web.js', 'utf8');
  const context = { window: { __leapContext: { commandID: 'web.run', query: 'initial' } },
    queueMicrotask, console, AbortController, setTimeout, clearTimeout };
  vm.runInNewContext(script, context);
  const bridge = context.window.leap;
  assert.ok(Object.isFrozen(bridge));
  let entered;
  bridge.onEnter(value => { entered = value; });
  await Promise.resolve();
  assert.equal(entered.commandID, 'web.run');
  assert.equal(entered.query, 'initial');
  const inputs = [];
  const remove = bridge.onInputChange(value => inputs.push(value.text));
  context.window.__leapDispatch('input', '中文输入');
  remove();
  context.window.__leapDispatch('input', 'latest');
  assert.deepEqual(inputs, ['中文输入']);
  bridge.onEnter(value => { entered = value; });
  await Promise.resolve();
  assert.equal(entered.query, 'latest');
  let submitted;
  bridge.onSubmit(value => { submitted = value; });
  context.window.__leapDispatch('submit', 'latest');
  assert.equal(submitted, 'latest');
  let exits = 0;
  bridge.onExit(() => { exits++; });
  context.window.__leapDispatch('exit', null);
  context.window.__leapDispatch('exit', null);
  assert.equal(exits, 1);
  assert.throws(() => bridge.onEnter(null), /函数/);
});
