'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { generate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/main');
const { validate, defaults } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/validation');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapGenerator-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { directory: root, name: '测试 "插件" </script>',
    id: 'com.example.test', version: '1.0.0', commandTitle: '测试', commandID: 'test.run',
    runtime: 'javascript', width: '800', height: '600', withUI: true };
}

test('五种模板生成且脚本按真实运行协议返回 hello', t => {
  const input = fixture(t);
  for (const [runtime, withUI] of [['javascript', false], ['javascript', true], ['python', false], ['python', true], ['shell', false]]) {
    const directory = path.join(input.directory, `${runtime}-${withUI}`);
    fs.mkdirSync(directory);
    const result = generate({ ...input, runtime, withUI, directory });
    assert.equal(result.directory, fs.realpathSync(directory));
    const manifest = JSON.parse(fs.readFileSync(path.join(result.directory, 'manifest.json'), 'utf8'));
    assert.equal(manifest.name, input.name);
    assert.equal(manifest.webEntry, withUI ? 'index.html' : undefined);
    assert.deepEqual(manifest.webWindow, withUI ? { width: 800, height: 600 } : undefined);
    const request = { jsonrpc: '2.0', id: 'test', method: 'leap.invoke', params: { commandID: input.commandID, query: '' } };
    const python = path.resolve('Resources/Leap/Runtimes/python-3.14.7/Versions/3.14/bin/python3.14');
    const executable = runtime === 'javascript' ? process.execPath : runtime === 'python' ? python : '/bin/zsh';
    const run = spawnSync(executable, [path.join(result.directory, manifest.entry)], {
      input: JSON.stringify(request) + '\n', encoding: 'utf8',
      env: { ...process.env, LEAP_COMMAND_ID: input.commandID },
    });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stderr, '');
    if (runtime === 'shell') assert.equal(run.stdout, 'hello\n');
    else assert.deepEqual(JSON.parse(run.stdout), { jsonrpc: '2.0', id: 'test', result: 'hello' });
    if (withUI) assert.ok(fs.readFileSync(path.join(result.directory, 'index.html'), 'utf8').includes('window.leap.invoke'));
  }
});

test('拒绝必填缺失、非法版本与路径穿越，不写入目录', t => {
  const input = fixture(t);
  for (const change of [{ name: '' }, { version: '1.0' }, { directory: '/tmp/../escape' },
    { directory: '/tmp/./escape' }, { id: '../id' }, { commandID: '../id' }, { commandTitle: 1 },
    { runtime: 'shell', withUI: true }, { directory: 'relative' }, { directory: '/' }, { withUI: 'yes' }]) {
    assert.throws(() => generate({ ...input, ...change }));
  }
  assert.deepEqual(fs.readdirSync(input.directory), []);
});

test('重复生成和包含隐藏文件、子目录的目录均拒绝，保留用户内容', t => {
  const input = fixture(t);
  const result = generate(input);
  const original = fs.readFileSync(path.join(result.directory, 'manifest.json'), 'utf8');
  assert.throws(() => generate(input), /空目录/);
  assert.equal(fs.readFileSync(path.join(result.directory, 'manifest.json'), 'utf8'), original);
  for (const name of ['hidden', 'subdirectory']) {
    const directory = path.join(input.directory, name);
    fs.mkdirSync(directory);
    if (name === 'hidden') fs.writeFileSync(path.join(directory, '.keep'), 'keep');
    else fs.mkdirSync(path.join(directory, 'nested'));
    assert.throws(() => generate({ ...input, directory }), /空目录/);
    assert.equal(fs.readdirSync(directory).length, 1);
  }
});

test('权限失败、部分写入失败只回滚本次文件，保留所选目录', t => {
  const input = fixture(t);
  const error = Object.assign(new Error('denied'), { code: 'EACCES' });
  assert.throws(() => generate(input, { ...fs, accessSync() { throw error; } }), { code: 'EACCES' });
  assert.deepEqual(fs.readdirSync(input.directory), []);
  let count = 0;
  assert.throws(() => generate(input, { ...fs, writeFileSync(...args) {
    if (++count === 2) {
      fs.writeFileSync(args[0], 'partial');
      fs.writeFileSync(path.join(input.directory, 'user-added'), 'keep');
      throw new Error('simulated disk failure');
    }
    return fs.writeFileSync(...args);
  } }), /simulated disk failure/);
  assert.deepEqual(fs.readdirSync(input.directory), ['user-added']);
  assert.equal(fs.readFileSync(path.join(input.directory, 'user-added'), 'utf8'), 'keep');
});

test('空目录检查后的并发文件和符号链接冲突不会被覆盖或删除', t => {
  const input = fixture(t);
  const external = path.join(path.dirname(input.directory), `${path.basename(input.directory)}-outside`);
  t.after(() => fs.rmSync(external, { force: true }));
  fs.writeFileSync(external, 'outside');
  for (const link of [false, true]) {
    assert.throws(() => generate(input, { ...fs, openSync(target, flags) {
      if (link) fs.symlinkSync(external, target);
      else fs.writeFileSync(target, 'user-added');
      return fs.openSync(target, flags);
    } }), { code: 'EEXIST' });
    const conflict = path.join(input.directory, 'manifest.json');
    assert.equal(fs.readFileSync(conflict, 'utf8'), link ? 'outside' : 'user-added');
    fs.unlinkSync(conflict);
  }
  assert.equal(fs.readFileSync(external, 'utf8'), 'outside');
});

test('回滚时保留用户替换的文件，未写入目标之外的位置', t => {
  const input = fixture(t);
  let count = 0;
  assert.throws(() => generate(input, { ...fs, writeFileSync(...args) {
    if (++count === 2) {
      const manifest = path.join(input.directory, 'manifest.json');
      // 用户将生成中的文件移走并在同一路径放入自己的文件。
      fs.renameSync(manifest, path.join(input.directory, 'user-backup'));
      fs.writeFileSync(manifest, 'user replacement');
      throw new Error('write interrupted');
    }
    return fs.writeFileSync(...args);
  } }), /write interrupted/);
  assert.deepEqual(fs.readdirSync(input.directory).sort(), ['manifest.json', 'user-backup']);
  assert.equal(fs.readFileSync(path.join(input.directory, 'manifest.json'), 'utf8'), 'user replacement');
});

test('目录缺失、非目录及损坏 JSON-RPC 返回可读错误', t => {
  const input = fixture(t);
  assert.throws(() => generate({ ...input, directory: path.join(input.directory, 'missing') }), { code: 'ENOENT' });
  const file = path.join(input.directory, 'file');
  fs.writeFileSync(file, 'keep');
  assert.throws(() => generate({ ...input, directory: file }), /不是目录/);
  const run = spawnSync(process.execPath, [path.resolve('Resources/Leap/OfficialPlugins/TemplateGenerator/main.js')], { input: '{}\n', encoding: 'utf8' });
  const response = JSON.parse(run.stdout);
  assert.equal(response.error.message, '无效的模板生成请求。');
  assert.ok(run.stderr.includes('模板生成失败'));
  assert.equal(validate(input).id, input.id);
});

test('网页尺寸校验及纯脚本忽略尺寸', t => {
  const input = fixture(t);
  for (const width of [undefined, '', '0', '-1', '399', '800.5', '8e2', NaN, Infinity, true]) {
    assert.throws(() => validate({ ...input, width }), /默认宽度/);
  }
  for (const height of [undefined, '299', 0, -1, '600.5']) {
    assert.throws(() => validate({ ...input, height }), /默认高度/);
  }
  assert.equal(validate({ ...input, width: 400, height: 300 }).width, 400);
  assert.equal(validate({ ...input, withUI: false, width: '' }).width, undefined);
  assert.deepEqual(fs.readdirSync(input.directory), []);
});

test('目录派生默认值支持中文、特殊字符、emoji 和手动覆盖', () => {
  const input = { directory: '/tmp/测试 插件😀/', name: '我的插件', version: '1.0.0',
    runtime: 'javascript', withUI: false };
  const value = validate(input);
  assert.equal(value.id, 'com.leap.plugin.u6d4bu8bd5u20u63d2u4ef6u1f600');
  assert.equal(value.commandID, `${value.id}.run`);
  assert.equal(value.commandTitle, '我的插件');
  assert.equal(defaults({ ...input, directory: '/other/测试 插件😀' }).id, value.id);
  assert.equal(defaults({ directory: '/tmp/My.Plugin_1-test' }).id, 'com.leap.plugin.My.Plugin_1-test');
  assert.equal(validate({ ...input, id: '  custom.id  ', commandID: ' ' }).commandID, 'custom.id.run');
  assert.equal(validate({ ...input, id: ' ', commandTitle: '\t' }).commandTitle, '我的插件');
  assert.equal(validate({ ...input, commandID: 'custom.run', commandTitle: '自定义' }).commandTitle, '自定义');
});
