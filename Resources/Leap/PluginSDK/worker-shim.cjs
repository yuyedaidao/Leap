'use strict';
// 在 Worker 线程里伪造出进程级的 stdin/stdout，让未修改的 bootstrap.cjs 以为自己仍是独立进程。
// argv 由 daemon 传入：[入口文件, 插件目录]，位置与独立进程时的 process.argv[2] 一致。
const { parentPort } = require('node:worker_threads');
const { PassThrough } = require('node:stream');
const { resolve } = require('node:path');

const entry = process.argv[2];
const directory = process.argv[3];

const input = new PassThrough();
Object.defineProperty(process, 'stdin', { value: input, configurable: true });

// 协议帧经 parentPort 转给 daemon，绝不写真正的 stdout，避免污染 daemon 自己的协议流。
process.stdout.write = (chunk, encoding, callback) => {
  parentPort.postMessage(typeof chunk === 'string' ? chunk : chunk.toString(encoding));
  if (typeof callback === 'function') callback();
  return true;
};

// Worker 里不支持 process.chdir，插件若问「我在哪」应得到自己的插件目录。
Object.defineProperty(process, 'cwd', { value: () => directory, configurable: true, writable: true });

parentPort.on('message', text => input.write(text));

// bootstrap.cjs 只在异步 IO 上使用 stdin；保持流处于流动状态，才会触发 'data'。
input.resume();

require(resolve(__dirname, 'bootstrap.cjs'));
