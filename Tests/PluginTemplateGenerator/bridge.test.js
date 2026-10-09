'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('真实注入脚本支持迟订阅、输入/提交/退出和移除监听', async () => {
  const swift = fs.readFileSync('Sources/Leap/PluginWebView.swift', 'utf8');
  // 从宿主提取实际注入内容，不维护第二份事件实现。
  const script = swift.match(/source: """([\s\S]*?)""",/)[1]
    .replace('\\(context.coordinator.initialContext)', '{"commandID":"web.run","query":"initial"}');
  const context = { window: {}, queueMicrotask, console };
  vm.runInNewContext(script, context);
  const bridge = context.window.leap;
  assert.ok(Object.isFrozen(bridge));
  let entered;
  bridge.onEnter(value => { entered = value; });
  await Promise.resolve();
  assert.equal(entered.commandID, 'web.run');
  assert.equal(entered.query, 'initial');
  const inputs = [];
  const remove = bridge.onInputChange(value => inputs.push(value));
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
