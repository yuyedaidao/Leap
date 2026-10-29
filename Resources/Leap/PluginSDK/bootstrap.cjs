'use strict';
const { format } = require('node:util');
const { resolve } = require('node:path');
const { AsyncLocalStorage } = require('node:async_hooks');
const eventContext = new AsyncLocalStorage();
const expiredCalls = new Set();

const write = process.stdout.write.bind(process.stdout);
const send = message => {
  const frame = JSON.stringify({ protocol: 1, ...message }) + '\n';
  if (Buffer.byteLength(frame) > 24 * 1024 * 1024) throw new Error('插件消息超过 24MB。');
  write(frame);
};
// console 属于开发者日志；标准输出专用于协议，避免调试文字损坏消息。
for (const key of ['log', 'info', 'warn', 'error', 'debug']) {
  console[key] = (...values) => process.stderr.write(format(...values) + '\n');
}
const listeners = { enter: new Set(), exit: new Set() };
const handlers = new Map();
const tasks = new Map();
const calls = new Map();
let active = true;
let entering = true;
let latestInput;
let items = [];
let listSnapshot = [];
let latestText = '';
let sequence = 0;

function subscribe(event, callback) {
  if (typeof callback !== 'function') throw new TypeError('监听器必须是函数。');
  if (listeners[event]) {
    listeners[event].add(callback);
    return () => listeners[event].delete(callback);
  }
  if (handlers.has(event)) throw new Error(`${event} 只能注册一个处理器。`);
  handlers.set(event, callback);
  return () => { if (handlers.get(event) === callback) handlers.delete(event); };
}

function hostCall(method, params = {}) {
  if (!active || entering) return Promise.reject(new Error('当前会话不可执行宿主操作。'));
  const context = eventContext.getStore();
  if (!context || context.signal.aborted) return Promise.reject(new Error('插件输入已取消。'));
  const id = `host-${++sequence}`;
  return new Promise((resolve, reject) => {
    const cancel = () => {
      clearTimeout(timer);
      cleanup();
      calls.delete(id);
      expiredCalls.add(id);
      send({ type: 'hostCancel', id });
      reject(new Error(context.signal.aborted ? '插件输入已取消。' : '宿主调用超时。'));
    };
    const timer = setTimeout(cancel, 60000);
    context.signal.addEventListener('abort', cancel, { once: true });
    const cleanup = () => context.signal.removeEventListener('abort', cancel);
    calls.set(id, { resolve, reject, timer, cleanup });
    try { send({ type: 'call', id, parentID: context.id, method, params }); }
    catch (error) { clearTimeout(timer); cleanup(); calls.delete(id); reject(error); }
  });
}

function validateItems(values) {
  if (!Array.isArray(values) || values.length > 100 || values.some(item =>
    !item || typeof item.id !== 'string' || !item.id || typeof item.title !== 'string' || !item.title ||
    (item.description !== undefined && typeof item.description !== 'string') ||
    (item.imagePath !== undefined && typeof item.imagePath !== 'string')) ||
    new Set(values.map(item => item.id)).size !== values.length) {
    throw new Error('列表最多 100 项，条目 ID 必须唯一且标题不能为空。');
  }
  // 保留协议规定的字段，不让不可序列化业务对象进入通信通道。
  return values.map(({ id, title, description, imagePath }) => ({
    id, title,
    ...(description !== undefined ? { description } : {}),
    ...(imagePath !== undefined ? { imagePath } : {}),
  }));
}

globalThis.leap = Object.freeze({
  onEnter: callback => subscribe('enter', callback),
  onInputChange: callback => subscribe('input', callback),
  onSelect: callback => subscribe('select', callback),
  onInvoke: callback => subscribe('invoke', callback),
  onExit: callback => subscribe('exit', callback),
  ...require('./host-api.js')(hostCall),
  outPlugin: () => hostCall('outPlugin'),
  hideMainWindow: () => hostCall('hideMainWindow'),
  log: (...values) => console.log(...values),
});
Object.defineProperty(globalThis, 'leap', { writable: false, configurable: false });

async function event(message) {
  const { id, method, params } = message;
  const controller = new AbortController();
  tasks.set(id, controller);
  return eventContext.run({ id, signal: controller.signal }, async () => {
    let live = true;
    try {
      if (!active && method !== 'exit') throw new Error('插件会话已退出。');
      if (typeof params?.commandID !== 'string' || typeof params.query !== 'string') {
        throw new Error('事件参数无效。');
      }
      let value = null;
      const context = { commandID: params.commandID, query: params.query, signal: controller.signal };
      if (method === 'enter') {
        entering = false;
        for (const callback of listeners.enter) await callback(context);
        entering = false;
      } else if (method === 'exit') {
        active = false;
        for (const task of tasks.values()) task.abort();
        for (const call of calls.values()) { clearTimeout(call.timer); call.cleanup(); call.reject(new Error('插件会话已退出。')); }
        calls.clear();
        for (const callback of listeners.exit) await callback();
      } else if (method === 'input') {
        latestInput = id;
        latestText = params.query;
        items = [];
        listSnapshot = [];
        let published = false;
        const setList = (values, options) => {
          if (!live || !active || controller.signal.aborted || latestInput !== id) return;
          const list = validateItems(values);
          if (options !== undefined && (!options || typeof options !== 'object' || Array.isArray(options)
            || (options.title !== undefined && typeof options.title !== 'string'))) {
            throw new TypeError('列表选项必须为对象，顶部标题必须为字符串。');
          }
          // 不传选项仍使用原数组协议，旧插件无需迁移。
          const snapshot = options?.title === undefined ? list : { items: list, title: options.title };
          send({ type: 'list', id, value: snapshot });
          items = list;
          listSnapshot = snapshot;
          published = true;
        };
        const handler = handlers.get('input');
        if (handler) await handler({ commandID: params.commandID, text: params.query, setList, signal: controller.signal });
        if (!published) setList([]);
        value = listSnapshot;
      } else if (method === 'select') {
        const item = items.find(item => item.id === params.itemID);
        if (!item || params.query !== latestText) throw new Error('所选条目已失效。');
        const handler = handlers.get('select');
        if (handler) value = (await handler({ commandID: params.commandID, text: params.query,
          item: Object.freeze({ ...item }), signal: controller.signal })) ?? null;
      } else if (method === 'invoke') {
        const handler = handlers.get('invoke');
        if (!handler) throw new Error('插件未注册动作处理器。');
        value = (await handler(context)) ?? null;
      } else { throw new Error('未知插件事件。'); }
      if (method !== 'input' && value !== null && typeof value !== 'string') throw new TypeError('动作反馈必须是字符串。');
      send({ type: 'result', id, value });
    } catch (error) {
      console.error(error?.message || String(error));
      send({ type: 'result', id, error: error?.message || String(error) });
    } finally {
      live = false;
      tasks.delete(id);
      if (method === 'exit') {
        for (const callbacks of Object.values(listeners)) callbacks.clear();
        handlers.clear();
      }
    }
  });
}

let frame = '';
let frameBytes = 0;
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  // 先限制累积输入，再处理分帧，防止无换行的输入无限占用内存。
  for (const part of chunk.split(/(?<=\n)/)) {
    frame += part;
    frameBytes += Buffer.byteLength(part);
    if (frameBytes > 24 * 1024 * 1024) { console.error('输入消息超过 24MB。'); process.exit(1); }
    if (!frame.endsWith('\n')) continue;
    try {
      const message = JSON.parse(frame);
      if (message.protocol !== 1 || typeof message.id !== 'string') throw new Error('无效协议消息。');
      if (message.type === 'event') void event(message);
      else if (message.type === 'cancel') tasks.get(message.id)?.abort();
      else if (message.type === 'result') {
        const call = calls.get(message.id);
        if (!call && expiredCalls.delete(message.id)) { frame = ''; frameBytes = 0; continue; }
        if (!call) throw new Error('宿主响应标识无效。');
        clearTimeout(call.timer); call.cleanup(); calls.delete(message.id);
        if (message.error) call.reject(new Error(message.error)); else call.resolve(message.value);
      } else { throw new Error('未知协议消息。'); }
    } catch (error) { console.error(error.message); process.exit(1); }
    frame = '';
    frameBytes = 0;
  }
});
process.stdin.on('end', () => process.exit(0));

try {
  require(resolve(process.argv[2]));
  send({ type: 'ready', id: 'ready', value: null });
} catch (error) { console.error(error.stack || error); process.exit(1); }
