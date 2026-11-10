'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { session } = require('../PluginSDK/session.cjs');
const { generate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/main');
const { validate } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/validation');
function fixture(t, runtime = 'javascript') {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapCommands-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return { directory, name: '多命令', version: '1.0.0', runtime, width: 800, height: 600,
    includeIcon: true, commands: [
      { id: 'direct.run', title: '直接', interaction: 'action', keywords: ['运行', 'run'] },
      { id: 'list.run', title: '列表', interaction: 'list', input: { enabled: true, placeholder: '转换文本' },
        matches: [{ type: 'text', minLength: 2, maxLength: 100 }] },
      { id: 'web.run', title: '网页', interaction: 'web', input: { enabled: true, placeholder: '网页参数' },
        matches: [{ type: 'regex', pattern: '(?i)^hello$', minLength: 1, maxLength: 1000 }] },
    ] };
}
for (const runtime of ['javascript', 'python']) test(`${runtime} 多命令按 ID 和方法分派且图标可用`, async t => {
  const input = fixture(t, runtime);
  const { directory } = generate(input);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')));
  assert.equal(manifest.commands.length, 3);
  assert.deepEqual(manifest.commands[0].keywords, ['运行', 'run']);
  assert.equal(manifest.commands[0].input, undefined);
  assert.equal(manifest.commands[1].input.placeholder, '转换文本');
  assert.equal(manifest.commands[2].input.enabled, true);
  assert.equal(manifest.commands[2].matches[0].pattern, '(?i)^hello$');
  assert.equal(manifest.icon, 'icon.png');
  assert.deepEqual(fs.readFileSync(path.join(directory, manifest.icon)).subarray(0, 8),
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const plugin = session(path.join(directory, manifest.entry), 'list.run', runtime);
  try {
    assert.equal((await plugin.call('invoke', 'Hello', undefined, 'direct.run')).value, 'hello');
    assert.equal((await plugin.call('invoke', 'Hello', undefined, 'web.run')).value, 'hello');
    assert.equal((await plugin.call('input', 'Hello')).items[0].title, 'HELLO');
    assert.equal((await plugin.call('select', 'Hello', 'lower')).value, 'hello');
    for (const id of ['missing', 'list.run']) {
      assert.ok((await plugin.call('invoke', 'Hello', undefined, id)).error);
    }
    assert.ok((await plugin.call('select', 'Hello', 'missing')).error);
  } finally { await plugin.close(); }

});

test('勾选图标时写入通用 plugin-icon.png，不用生成器自身图标', t => {
  const input = fixture(t);
  generate(input);
  const generator = path.join(__dirname, '../../Resources/Leap/OfficialPlugins/TemplateGenerator');
  const icon = fs.readFileSync(path.join(input.directory, 'icon.png'));
  assert.ok(icon.equals(fs.readFileSync(path.join(generator, 'plugin-icon.png'))));
  assert.ok(!icon.equals(fs.readFileSync(path.join(generator, 'default-icon.png'))));
});

test('Shell 多命令支持后台，未知 ID 非零退出', t => {
  const input = fixture(t, 'shell');
  input.commands = [{ id: 'front', interaction: 'action' }, { id: 'back', interaction: 'action', executionMode: 'background' }];
  generate(input);
  const manifest = JSON.parse(fs.readFileSync(path.join(input.directory, 'manifest.json')));
  assert.equal(manifest.commands[1].executionMode, 'background');
  assert.equal(manifest.webEntry, undefined);
  for (const id of ['front', 'back', 'unknown']) {
    const result = spawnSync('/bin/zsh', [path.join(input.directory, 'main.zsh')], {
      env: { ...process.env, LEAP_COMMAND_ID: id }, encoding: 'utf8',
    });
    assert.equal(result.status, id === 'unknown' ? 1 : 0);
    assert.equal(result.stdout, id === 'unknown' ? '' : 'hello\n');
  }
  // 每条命令各自一个分支，用户才能给不同命令写不同逻辑。
  const source = fs.readFileSync(path.join(input.directory, 'main.zsh'), 'utf8');
  assert.ok(source.includes("'front')") && source.includes("'back')"));
});

test('空数组、重复ID、非法组合及匹配边界均在写入前拒绝', t => {
  const input = fixture(t);
  const invalid = [[], [{ id: 'same', interaction: 'action' }, { id: 'same', interaction: 'action' }],
    [{ interaction: 'list', input: { enabled: false } }],
    [{ interaction: 'action', input: { enabled: true } }],
    [{ interaction: 'web', executionMode: 'background' }],
    [{ interaction: 'action', keywords: [''] }],
    [{ interaction: 'action', matches: [{ type: 'text', pattern: 'x' }] }],
    ...[{ minLength: 0 }, { minLength: 2, maxLength: 1 }, { maxLength: 10001 }, { minLength: '1.5' },
      { type: 'regex', pattern: '' }, { type: 'regex', pattern: 'x'.repeat(1001) }]
      .map(rule => [{ interaction: 'action', matches: [{ type: 'text', ...rule }] }]),
  ];
  for (const commands of invalid) assert.throws(() => generate({ ...input, commands }));
  for (const minimumHostVersion of ['1.1', '1.2.3.4', 'invalid', 1]) {
    assert.throws(() => generate({ ...input, minimumHostVersion }));
  }
  // 留空或合法三段数字都允许，模板本身不固定宿主版本。
  for (const minimumHostVersion of ['', '0.0.1', '9.9.9']) {
    const manifest = validate({ ...input, minimumHostVersion, commands: [{ interaction: 'action' }] });
    assert.equal(manifest.minimumHostVersion, minimumHostVersion || undefined);
  }
  assert.throws(() => generate({ ...input, id: 'a..b' }));
  assert.deepEqual(fs.readdirSync(input.directory), []);
  assert.throws(() => generate({ ...input,
    commands: [{ interaction: 'action', matches: [{ type: 'regex', pattern: '(' }] }] }), /正则表达式无效/);
  assert.deepEqual(fs.readdirSync(input.directory), []);
  const value = validate({ ...input, commands: [{ interaction: 'action',
    matches: [{ type: 'text', minLength: 1, maxLength: 10000 }] }] });
  assert.equal(value.commands[0].matches[0].maxLength, 10000);
});

test('默认图标写入失败只回滚本次创建文件', t => {
  const input = fixture(t);
  input.commands = [{ interaction: 'action' }];
  assert.throws(() => generate(input, { ...fs, writeFileSync(fd, contents, options) {
    if (Buffer.isBuffer(contents)) {
      fs.writeFileSync(path.join(input.directory, 'user-file'), 'keep');
      throw new Error('icon write failed');
    }
    return fs.writeFileSync(fd, contents, options);
  } }), /icon write failed/);
  assert.deepEqual(fs.readdirSync(input.directory), ['user-file']);
});

test('生成网页使用当前命令与顶部参数，退出后移除监听', async t => {
  const input = fixture(t);
  generate(input);
  const html = fs.readFileSync(path.join(input.directory, 'index.html'), 'utf8');
  const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const listeners = {};
  const removed = [];
  const calls = [];
  const button = { disabled: true, addEventListener(_, callback) { this.click = callback; } };
  const output = { textContent: '' };
  const bridge = { invoke: async (id, query) => { calls.push([id, query]); return 'hello'; } };
  for (const event of ['Enter', 'InputChange', 'Submit', 'Exit']) bridge[`on${event}`] = callback => {
    listeners[event] = callback;
    return () => removed.push(event);
  };
  vm.runInNewContext(source, { window: { leap: bridge }, document: {
    getElementById: id => id === 'invoke' ? button : output,
  } });
  assert.equal(button.disabled, true);
  listeners.Enter({ commandID: 'web.second', query: 'initial' });
  await button.click();
  listeners.InputChange({ text: 'changed' });
  await listeners.Submit('submitted');
  assert.deepEqual(calls, [['web.second', 'initial'], ['web.second', 'submitted']]);
  listeners.Exit();
  assert.deepEqual(removed, ['Enter', 'InputChange', 'Submit']);
  await button.click();
  assert.equal(calls.length, 2);
});


test('新命令数组优先于旧参数，Shell缺省直接执行，官方ID不能生成', () => {
  const input = { directory: '/tmp/plugin', name: '插件', version: '1.0.0', runtime: 'shell',
    commandID: '../ignored', commandTitle: 42, withUI: true, commands: [{ id: 'shell.run' }] };
  const result = validate(input);
  assert.equal(result.commands[0].interaction, 'action');
  assert.equal(result.commands[0].id, 'shell.run');
  assert.throws(() => validate({ ...input, id: 'com.padding.leap.template-generator' }), /内置插件保留/);
});
