'use strict';
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const path = require('node:path');

// 测试使用真实管道和随包 SDK，验证会话复用而非模拟业务处理器。
function session(entry, commandID, runtime = 'javascript', hostCall = async () => true) {
  const executable = runtime === 'python'
    ? path.resolve(__dirname, '../../Resources/Leap/Runtimes/python-3.14.7/Versions/3.14/bin/python3.14') : process.execPath;
  const bootstrap = path.resolve(__dirname, '../../Resources/Leap/PluginSDK', runtime === 'python' ? 'bootstrap.py' : 'bootstrap.cjs');
  const child = spawn(executable, [bootstrap, path.resolve(entry)], { stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  let sequence = 0;
  let closing = false;
  let stderr = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const readyTimer = setTimeout(() => readyReject(new Error('SDK 启动超时：' + stderr)), 3000);
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-65536); });
  const send = (message, splitIndex) => {
    const data = Buffer.from(JSON.stringify({ protocol: 1, ...message }) + '\n');
    if (splitIndex !== undefined) {
      child.stdin.write(data.subarray(0, splitIndex)); child.stdin.write(data.subarray(splitIndex));
    } else child.stdin.write(data);
  };
  createInterface({ input: child.stdout }).on('line', async line => {
    const message = JSON.parse(line);
    if (message.type === 'ready') { clearTimeout(readyTimer); readyResolve(); return; }
    if (message.type === 'call') {
      try { send({ type: 'result', id: message.id, value: await hostCall(message.method, message.params) }); }
      catch (error) { send({ type: 'result', id: message.id, error: error.message }); }
      return;
    }
    const call = pending.get(message.id);
    if (!call) return;
    if (message.type === 'list') { call.items = message.value; call.updates.push(message.value); return; }
    clearTimeout(call.timer);
    pending.delete(message.id);
    call.resolve({ ...message, items: call.items, updates: call.updates });
  });
  child.on('error', error => { clearTimeout(readyTimer); readyReject(error); });
  child.on('exit', () => {
    clearTimeout(readyTimer); readyReject(new Error('SDK 退出：' + stderr));
    for (const call of pending.values()) { clearTimeout(call.timer); call.reject(new Error('SDK 退出：' + stderr)); }
    pending.clear();
  });
  let entered = false;
  async function request(method, query = '', itemID, override = {}, splitIndex) {
    await ready;
    const id = String(++sequence);
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('事件超时：' + stderr)); }, 3500);
      pending.set(id, { resolve, reject, timer, items: [], updates: [] });
    });
    send({ type: 'event', id, method, params: { commandID, query, itemID }, ...override }, splitIndex);
    return response;
  }
  return {
    child, ready, request, send,
    async call(method, query = '', itemID, command = commandID) {
      if (!entered) { await request('enter'); entered = true; }
      return request(method, query, itemID, { params: { commandID: command, query, itemID } });
    },
    async close() {
      if (closing) return;
      closing = true;
      if (child.exitCode === null && !child.killed) {
        try { if (entered) await request('exit'); } finally { child.stdin.end(); }
      }
    },
    get stderr() { return stderr; },
  };
}
module.exports = { session };
