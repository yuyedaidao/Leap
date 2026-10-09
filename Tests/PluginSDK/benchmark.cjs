'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const { session } = require('./session.cjs');

async function main() {
  const baseline = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapBaseline-'));
  const entry = path.join(baseline, 'main.js');
  // 从迁移前提交读取实际入口，只在临时目录测量，不保留旧协议实现。
  fs.writeFileSync(entry, execFileSync('git', ['show', '2757829:Examples/Plugins/TextConvert/main.js']));
  const legacy = [];
  try {
    for (let index = 0; index < 100; index++) {
      const start = performance.now();
      const child = spawnSync(process.execPath, [entry], { encoding: 'utf8', timeout: 3000,
        input: JSON.stringify({jsonrpc:'2.0',id:String(index),method:'leap.query',
          params:{commandID:'text.convert',query:'Hello'}})+'\n' });
      if (child.status !== 0) throw new Error(child.stderr);
      legacy.push(performance.now() - start);
    }
  } finally { fs.rmSync(baseline, {recursive:true,force:true}); }
  const plugin = session(path.resolve('Examples/Plugins/TextConvert/main.js'), 'text.convert');
  try {
  const warm = [];
  const coldStart = performance.now();
  await plugin.call('input', 'Hello');
  const cold = performance.now() - coldStart;
  const pid = plugin.child.pid;
  for (let index = 0; index < 100; index++) {
    const start = performance.now();
    const result = await plugin.call('input', 'Hello' + index);
    if (result.items.length !== 2 || plugin.child.pid !== pid) throw new Error('会话未复用或结果无效。');
    warm.push(performance.now() - start);
  }
  const before = execFileSync('ps', ['-p', String(pid), '-o', 'time='], {encoding:'utf8'}).trim();
  await new Promise(resolve => setTimeout(resolve, 1000));
  const after = execFileSync('ps', ['-p', String(pid), '-o', 'time='], {encoding:'utf8'}).trim();
  const percentiles = samples => {
    samples.sort((a,b) => a-b);
    return {p50:samples[49],p95:samples[94]};
  };
  console.log(JSON.stringify({ environment: {platform:process.platform,arch:process.arch,node:process.version,
    cpu:os.cpus()[0].model}, samples:100, oldProcessPerInputMs:percentiles(legacy),
    sdkColdMs:cold, sdkWarmTransportMs:percentiles(warm), processStarts:1,
    idleCPUTimeBefore:before,idleCPUTimeAfter:after }, null, 2));
  } finally { await plugin.close(); }
}
main().catch(error => { console.error(error); process.exitCode=1; });
