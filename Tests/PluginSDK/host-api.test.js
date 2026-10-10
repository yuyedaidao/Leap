'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const create = require('../../Resources/Leap/PluginSDK/host-api.js');
const { session } = require('./session.cjs');

test('共享包装器的参数、结构化结果、校验及图片大小边界', async () => {
  const calls = [];
  const sdk = create((method, params) => { calls.push({ method, params }); return [{ path: '/tmp/a' }]; });
  assert.deepEqual(await sdk.getCopyedFiles(), [{ path: '/tmp/a' }]);
  await sdk.copyFile(['/tmp/a', '/tmp/b']);
  await sdk.copyImage(new Uint8Array([0, 1, 255]));
  await sdk.showNotification('测试', 'run');
  await sdk.simulateKeyboardTap('v', 'command');
  assert.deepEqual(calls.slice(1), [
    { method: 'copyFile', params: { filePath: ['/tmp/a', '/tmp/b'] } },
    { method: 'copyImage', params: { image: 'data:application/octet-stream;base64,AAH/' } },
    { method: 'showNotification', params: { body: '测试', clickFeatureCode: 'run' } },
    { method: 'simulateKeyboardTap', params: { key: 'v', modifiers: ['command'] } },
  ]);
  for (const action of [() => sdk.copyFile([]), () => sdk.copyFile([null]), () => sdk.copyText(null),
    () => sdk.copyImage(new Uint8Array()), () => sdk.copyImage(new Uint8Array(16 * 1024 * 1024 + 1)),
    () => sdk.simulateKeyboardTap('a', 1), () => sdk.showNotification('')]) {
    await assert.rejects(action(), TypeError);
  }
  const bytes = new Uint8Array(16 * 1024 * 1024);
  await sdk.copyImage(bytes);
  assert.ok(calls.at(-1).params.image.length < 24 * 1024 * 1024);
  await assert.rejects(create(() => { throw new Error('权限拒绝'); }).shellBeep(), /权限拒绝/);
});

test('真实网页桥接返回结构化数据，退出后禁止调用', async () => {
  const calls = [];
  const window = { __leapContext: { commandID: 'run', query: '' }, webkit: { messageHandlers: {
    leapHost: { postMessage: async value => { calls.push(value); return { value: '结构化' }; } },
  } } };
  const scope = { window, Uint8Array, TextEncoder, AbortController, queueMicrotask, console, btoa, setTimeout, clearTimeout };
  const source = fs.readFileSync('Resources/Leap/PluginSDK/host-api.js', 'utf8') + '\n'
    + fs.readFileSync('Resources/Leap/PluginSDK/web.js', 'utf8');
  vm.runInNewContext(source, scope);
  assert.deepEqual(await window.leap.getAppName(), { value: '结构化' });
  await window.leap.copyImage(new Uint8Array([0, 1, 255]));
  assert.equal(calls.at(-1).params.image, 'data:application/octet-stream;base64,AAH/');
  window.__leapDispatch('exit', null);
  await assert.rejects(window.leap.getPath('home'), /已退出/);
});

test('网页取消宿主等待，发送与接收均限制通信帧且不会破坏后续调用', async () => {
  const calls = [];
  const window = { __leapContext: { commandID: 'run', query: '' }, webkit: { messageHandlers: {
    leapHost: { postMessage: value => {
      calls.push(value);
      if (value.method === 'readCurrentBrowserUrl') return new Promise(() => {});
      return Promise.resolve(value.method === 'getFileIcon' ? 'x'.repeat(24 * 1024 * 1024) : true);
    } },
  } } };
  const source = fs.readFileSync('Resources/Leap/PluginSDK/host-api.js', 'utf8') + '\n'
    + fs.readFileSync('Resources/Leap/PluginSDK/web.js', 'utf8');
  vm.runInNewContext(source, { window, Uint8Array, TextEncoder, AbortController,
    queueMicrotask, console, btoa, setTimeout, clearTimeout });
  const pending = window.leap.readCurrentBrowserUrl();
  window.__leapDispatch('input', 'next');
  await assert.rejects(pending, /输入已取消/);
  assert.equal(calls.at(-1).method, '__cancelHostCall');
  assert.equal(calls.at(-1).params.callID, calls[0].callID);
  await assert.rejects(window.leap.copyText('x'.repeat(24 * 1024 * 1024)), /超过 24MB/);
  await assert.rejects(window.leap.getFileIcon('folder'), /超过 24MB/);
  assert.equal(await window.leap.shellBeep(), true);
});

for (const runtime of ['javascript', 'python']) {
  test(`${runtime} 真实 SDK 参数编码、系统结果及错误传播`, async t => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapHostAPI-'));
    const entry = path.join(directory, runtime === 'python' ? 'main.py' : 'main.js');
    const script = runtime === 'python' ? `
import json
def invoke(context):
    if context['query'] == 'error':
        return str(leap.getPath('invalid'))
    leap.copyImage(image=bytearray([0, 1, 255]))
    leap.copyFile(['/tmp/a'])
    leap.simulateKeyboardTap('v', 'command')
    return json.dumps(leap.getCopyedFiles())
leap.onInvoke(invoke)
` : `leap.onInvoke(async ({query}) => {
  if (query === 'error') return String(await leap.getPath('invalid'));
  await leap.copyImage(new Uint8Array([0, 1, 255]));
  await leap.copyFile(['/tmp/a']);
  await leap.simulateKeyboardTap('v', 'command');
  return JSON.stringify(await leap.getCopyedFiles());
});`;
    fs.writeFileSync(entry, script);
    const calls = [];
    const plugin = session(entry, 'run', runtime, async (method, params) => {
      calls.push({ method, params });
      if (method === 'getPath') throw new Error('不支持的系统路径名称。');
      return method === 'getCopyedFiles' ? [{ path: '/tmp/a', isFile: true, isDiractory: false, name: 'a' }] : true;
    });
    t.after(async () => { await plugin.close(); fs.rmSync(directory, { recursive: true, force: true }); });
    const response = await plugin.call('invoke');
    assert.equal(JSON.parse(response.value)[0].path, '/tmp/a');
    assert.equal(calls[0].params.image, 'data:application/octet-stream;base64,AAH/');
    assert.deepEqual(calls[2].params, { key: 'v', modifiers: ['command'] });
    assert.match((await plugin.call('invoke', 'error')).error, /不支持的系统路径/);
  });
}
