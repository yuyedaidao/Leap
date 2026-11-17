'use strict';
// 常驻 daemon：一个 node 进程里用 Worker 承载所有 JS 插件会话。
// 与宿主之间仍是一行一个 JSON；每条插件帧额外带 session 字段用于路由。
const { Worker } = require('node:worker_threads');
const { resolve } = require('node:path');

const shim = resolve(__dirname, 'worker-shim.cjs');
const workers = new Map();
const write = process.stdout.write.bind(process.stdout);

function send(message) {
  write(JSON.stringify(message) + '\n');
}

function report(op, session, detail) {
  send({ type: '__daemon', op, session, detail });
}

// 插件侧宿主调用 id 是 host-N、就绪帧 id 是 ready，都是进程内计数，跨会话会撞；出口统一加会话前缀。
function scopeOut(session, text) {
  const body = text.trim();
  if (!body) return;
  let message;
  try {
    message = JSON.parse(body);
  } catch {
    // 插件往 stdout 打非协议内容时丢弃，避免污染宿主协议流
    return;
  }
  if (typeof message.id === 'string' && (message.id === 'ready' || message.id.startsWith('host-'))) {
    message.id = session + '/' + message.id;
  }
  message.session = session;
  send(message);
}

// 防御性去前缀：当前回程帧（request/notify/exit 用会话自己的 UUID、host 回帧用裸 id）都不带前缀，
// 所以这里实际上不会命中，保留是为了让出口/回程两侧对称。
function scopeIn(session, message) {
  if (typeof message.id === 'string' && message.id.startsWith(session + '/')) {
    const rest = message.id.slice(session.length + 1);
    if (rest === 'ready' || rest.startsWith('host-')) message.id = rest;
  }
  return message;
}

function spawn(session, entry, directory) {
  const existing = workers.get(session);
  if (existing) terminate(session, existing);

  // 所有插件共享一个进程，给单个 Worker 的堆封顶，避免一个插件泄漏拖垮整层。
  const worker = new Worker(shim, { argv: [entry, directory], resourceLimits: { maxOldGenerationSizeMb: 256 } });
  workers.set(session, worker);

  worker.on('message', text => {
    for (const line of String(text).split('\n')) scopeOut(session, line);
  });
  worker.on('error', error => {
    report('fatal', session, String((error && error.stack) || error));
  });
  worker.on('exit', code => {
    if (workers.get(session) !== worker) return;
    workers.delete(session);
    report('exited', session, String(code));
  });
}

function terminate(session, worker) {
  if (workers.get(session) === worker) workers.delete(session);
  worker.terminate().catch(() => {});
}

function deliver(session, envelope) {
  const worker = workers.get(session);
  if (!worker) return;
  // 信封里的 op/session 只是 daemon 路由信息，插件侧只该看到原本的协议帧
  const message = envelope.message;
  if (!message || typeof message !== 'object') return;
  worker.postMessage(JSON.stringify(scopeIn(session, message)) + '\n');
}

function close(session) {
  const worker = workers.get(session);
  if (!worker) return;
  // 先给插件一次自行收尾的机会，宽限期后才硬停，与 per-process 路径的 0.25s 宽限保持一致
  // bootstrap.cjs 对非 notify 事件都要求 params.commandID/query，退出帧也不例外
  try {
    const exit = { protocol: 1, type: 'event', id: session + '/exit', method: 'exit', params: { commandID: '', query: '' } };
    worker.postMessage(JSON.stringify(exit) + '\n');
  } catch {}
  workers.delete(session);
  setTimeout(() => worker.terminate().catch(() => {}), 250);
}

function handle(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (typeof message.session !== 'string') return;
  switch (message.op) {
    case 'spawn':
      spawn(message.session, message.entry, message.directory);
      return;
    case 'write':
      deliver(message.session, message);
      return;
    case 'close':
      close(message.session);
      return;
    default:
      return;
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  let index = buffer.indexOf('\n');
  while (index >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (line.trim()) handle(line);
    index = buffer.indexOf('\n');
  }
});
process.stdin.on('end', () => {
  for (const session of [...workers.keys()]) close(session);
  setTimeout(() => process.exit(0), 300);
});

process.on('uncaughtException', error => {
  process.stderr.write('daemon 未捕获异常：' + String((error && error.stack) || error) + '\n');
});
process.on('unhandledRejection', error => {
  process.stderr.write('daemon 未处理拒绝：' + String((error && error.stack) || error) + '\n');
});
