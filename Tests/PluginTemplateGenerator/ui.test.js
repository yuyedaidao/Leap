'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { validate, defaults } = require('../../Resources/Leap/OfficialPlugins/TemplateGenerator/validation');

// 无浏览器依赖的交互测试：在 DOM 边界模拟元素，真实执行 ui.js 与共享校验。
function page(bridge = {}) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: '', checked: false, disabled: false, hidden: false, dataset: {}, textContent: '',
      handlers: {}, addEventListener(event, handler) { this.handlers[event] = handler; },
    });
    return elements.get(id);
  };
  const fieldIDsForCard = { id: 'commandID', title: 'commandTitle', interaction: 'interaction',
    executionMode: 'executionMode', inputEnabled: 'inputEnabled', placeholder: 'inputPlaceholder', keywords: 'keywords' };
  const makeCard = (first = false) => {
    const local = new Map();
    const rows = [];
    const get = selector => {
      const match = selector.match(/^\[data-field="(.+)"\]$/);
      if (match && first) return element(fieldIDsForCard[match[1]]);
      if (!local.has(selector)) local.set(selector, { value: '', checked: false, disabled: false,
        hidden: false, handlers: {}, textContent: '', addEventListener(event, handler) { this.handlers[event] = handler; },
        append() {}, remove() {} });
      if (selector === '[data-matches]') local.get(selector).append = row => {
        rows.push(row);
        row.remove = () => rows.splice(rows.indexOf(row), 1);
      };
      return local.get(selector);
    };
    if (!first) {
      get('[data-field="interaction"]').value = 'web';
      get('[data-field="executionMode"]').value = 'foreground';
    }
    return { dataset: { ordinal: '1' }, querySelector: get, querySelectorAll: selector => selector === '.match-row' ? rows : [],
      cloneNode: () => makeCard(), removeAttribute() {}, remove() {} };
  };
  const makeMatch = () => {
    const fields = new Map();
    const get = selector => {
      if (!fields.has(selector)) fields.set(selector, { value: '', hidden: false, disabled: false, handlers: {},
        addEventListener(event, handler) { this.handlers[event] = handler; } });
      return fields.get(selector);
    };
    for (const [key, value] of Object.entries({ type: 'text', minLength: '1', maxLength: '1000' })) {
      get(`[data-match="${key}"]`).value = value;
    }
    return { querySelector: get, cloneNode: makeMatch };
  };
  elements.set('matchTemplate', { content: { firstElementChild: makeMatch() } });
  elements.set('firstCommand', makeCard(true));
  element('executionMode').value = 'foreground';
  element('commands').children = [];
  element('commands').append = card => element('commands').children.push(card);
  const initial = { directory: '/tmp/plugin', name: '插件', id: '',
    version: '1.0.0', commandTitle: '运行插件', commandID: '', runtime: 'javascript', interaction: 'web', width: '800', height: '600' };
  const fieldIDs = { id: 'pluginID', name: 'pluginName' };
  const values = {};
  for (const [name, value] of Object.entries(initial)) {
    const field = element(fieldIDs[name] || name);
    field.value = value;
    Object.defineProperty(values, name, { enumerable: true, get: () => field.value, set: next => { field.value = next; } });
  }
  element('runtime').value = 'javascript';
  element('interaction').value = 'web';
  const context = {
    document: { getElementById: element }, window: { leap: bridge, templateValidation: { validate, defaults } },
    FormData: function () { return Object.entries(values); },
  };
  vm.runInNewContext(fs.readFileSync(path.resolve('Resources/Leap/OfficialPlugins/TemplateGenerator/ui.js'), 'utf8'), context);
  const fire = (id, event) => element(id).handlers[event]({ preventDefault() {} });
  return { element, values, fire };
}

test('ID 与标题保持空值，用动态占位提示展示默认值', async () => {
  let selected = '/tmp/another-plugin';
  const ui = page({ chooseDirectory: async () => selected });
  assert.equal(ui.element('pluginID').value, '');
  assert.equal(ui.element('commandID').value, '');
  assert.equal(ui.element('pluginID').placeholder, 'com.leap.plugin.plugin');
  assert.equal(ui.element('commandID').placeholder, 'com.leap.plugin.plugin.run');
  assert.equal(ui.element('commandTitle').placeholder, '插件');
  ui.values.name = '新名称';
  ui.fire('pluginName', 'input');
  assert.equal(ui.element('commandTitle').placeholder, '新名称');
  ui.values.id = 'custom.plugin';
  ui.fire('pluginID', 'input');
  assert.equal(ui.element('commandID').placeholder, 'custom.plugin.run');
  ui.values.commandID = 'custom.run';
  ui.values.commandTitle = '自定义标题';
  await ui.fire('choose', 'click');
  assert.equal(ui.element('pluginID').placeholder, 'com.leap.plugin.another-plugin');
  assert.equal(ui.values.id, 'custom.plugin');
  assert.equal(ui.values.commandID, 'custom.run');
  assert.equal(ui.values.commandTitle, '自定义标题');
});

test('高级设置留空时提交使用共享默认值', async () => {
  let submitted;
  const ui = page({
    invoke: async (_, query) => { submitted = JSON.parse(query); return JSON.stringify({ directory: '/tmp/plugin' }); },
    openDirectory: async () => {},
  });
  ui.values.commandTitle = '   ';
  await ui.fire('generator', 'submit');
  assert.equal(submitted.id, 'com.leap.plugin.plugin');
  assert.equal(submitted.commands[0].id, 'com.leap.plugin.plugin.run');
  assert.equal(submitted.commands[0].title, '插件');
  assert.equal(submitted.directory, '/tmp/plugin');
  assert.equal(ui.element('pluginID').value, '');
});

test('目录取消保留当前输入，选择成功清空旧生成结果', async () => {
  let selection = null;
  const ui = page({ chooseDirectory: async () => selection });
  ui.element('directory').value = '/tmp/original';
  await ui.fire('choose', 'click');
  assert.equal(ui.element('directory').value, '/tmp/original');
  selection = '/tmp/new';
  await ui.fire('choose', 'click');
  assert.equal(ui.element('directory').value, '/tmp/new');
  assert.equal(ui.element('generate').disabled, false);
});

test('Shell 仅能直接执行，切回Python可选择列表或网页', () => {
  const ui = page();
  ui.element('runtime').value = 'shell';
  ui.fire('runtime', 'change');
  assert.equal(ui.element('interaction').value, 'action');
  assert.equal(ui.element('interaction').disabled, true);
  assert.equal(ui.element('width').disabled, true);
  assert.equal(ui.element('widthOption').hidden, true);
  ui.element('runtime').value = 'python';
  ui.fire('runtime', 'change');
  assert.equal(ui.element('interaction').disabled, false);
  ui.element('interaction').value = 'list';
  ui.fire('interaction', 'change');
  assert.equal(ui.element('heightOption').hidden, true);
  ui.element('pluginID').value = 'com.example.new';
  ui.fire('pluginID', 'input');
  assert.equal(ui.element('commandID').placeholder, 'com.example.new.run');
  ui.element('commandID').value = 'custom.run';
  ui.element('pluginID').value = 'com.example.changed';
  ui.fire('pluginID', 'input');
  assert.equal(ui.element('commandID').value, 'custom.run');
});

test('网页 UI 开关启用尺寸输入，尺寸错误不会发送请求', async () => {
  let calls = 0;
  const ui = page({ invoke: async () => { calls++; throw new Error('unused'); } });
  assert.equal(ui.element('width').disabled, false);
  assert.equal(ui.element('widthOption').hidden, false);
  assert.equal(ui.element('heightOption').hidden, false);
  ui.values.width = '399';
  await ui.fire('generator', 'submit');
  assert.equal(calls, 0);
  assert.ok(ui.element('status').textContent.includes('默认宽度'));
  ui.element('interaction').value = 'action';
  await ui.fire('interaction', 'change');
  assert.equal(ui.element('width').disabled, true);
  assert.equal(ui.element('widthOption').hidden, true);
  assert.equal(ui.element('heightOption').hidden, true);
  await ui.fire('generator', 'submit');
  assert.equal(calls, 1);
  ui.element('interaction').value = 'web';
  ui.fire('interaction', 'change');
  assert.equal(ui.element('widthOption').hidden, false);
  assert.equal(ui.element('heightOption').hidden, false);
  assert.equal(ui.element('width').disabled, false);
  assert.equal(ui.element('width').value, '399');
});

test('重复提交只发一次请求，Finder 失败仍保留目录并允许重试', async () => {
  let resolve;
  let invokes = 0;
  let opens = 0;
  let shouldFail = true;
  const ui = page({
    invoke: async () => { invokes++; return new Promise(done => { resolve = done; }); },
    openDirectory: async directory => {
      opens++;
      assert.equal(directory, '/tmp/plugin');
      if (shouldFail) throw new Error('Finder unavailable');
    },
  });
  const first = ui.fire('generator', 'submit');
  assert.equal(ui.element('fields').disabled, true);
  await ui.fire('generator', 'submit');
  assert.equal(invokes, 1);
  resolve(JSON.stringify({ directory: '/tmp/plugin' }));
  await first;
  assert.equal(ui.element('generatedPath').textContent, '/tmp/plugin');
  assert.ok(ui.element('status').textContent.includes('Finder unavailable'));
  assert.equal(ui.element('open').hidden, false);
  assert.equal(ui.element('fields').disabled, false);
  shouldFail = false;
  await ui.fire('open', 'click');
  assert.equal(opens, 2);
  assert.ok(ui.element('status').textContent.includes('已用 Finder 打开'));
});

test('校验失败不调用脚本；脚本失败恢复表单', async () => {
  let calls = 0;
  const ui = page({ invoke: async () => { calls++; throw new Error('没有权限写入'); } });
  ui.values.version = 'invalid';
  await ui.fire('generator', 'submit');
  assert.equal(calls, 0);
  ui.values.version = '1.0.0';
  await ui.fire('generator', 'submit');
  assert.equal(calls, 1);
  assert.ok(ui.element('status').textContent.includes('没有权限写入'));
  assert.equal(ui.element('generate').disabled, false);
  assert.equal(ui.element('open').hidden, true);
});


test('多命令添加避开已占用ID，删除后不重排，Shell后台提交正确', async () => {
  let submitted;
  const ui = page({ invoke: async (_, query) => {
    submitted = JSON.parse(query); return JSON.stringify({ directory: '/tmp/plugin' });
  }, openDirectory: async () => {} });
  ui.values.commandID = 'com.leap.plugin.plugin.run2';
  ui.fire('addCommand', 'click');
  const card = ui.element('commands').children[0];
  const field = name => card.querySelector(`[data-field="${name}"]`);
  assert.equal(field('id').placeholder, 'com.leap.plugin.plugin.run3');
  field('title').value = '第二个命令';
  field('interaction').value = 'list';
  field('interaction').handlers.change();
  assert.equal(field('inputEnabled').checked, true);
  assert.equal(field('inputEnabled').disabled, true);
  ui.element('firstCommand').querySelector('[data-remove-command]').handlers.click();
  assert.equal(field('id').placeholder, 'com.leap.plugin.plugin.run3');
  assert.equal(card.querySelector('[data-remove-command]').disabled, true);
  ui.values.runtime = 'shell';
  ui.fire('runtime', 'change');
  assert.equal(field('interaction').value, 'action');
  field('executionMode').value = 'background';
  await ui.fire('generator', 'submit');
  assert.equal(submitted.commands.length, 1);
  assert.equal(submitted.commands[0].id, 'com.leap.plugin.plugin.run3');
  assert.equal(submitted.commands[0].executionMode, 'background');
  assert.equal(submitted.commands[0].input, undefined);
  ui.values.runtime = 'python';
  ui.fire('runtime', 'change');
  assert.equal(field('executionMode').value, 'foreground');
});


test('表单多条匹配、关键词、顶部输入与图标进入生成请求，删除规则生效', async () => {
  let submitted;
  const ui = page({ invoke: async (_, query) => {
    submitted = JSON.parse(query); return JSON.stringify({ directory: '/tmp/plugin' });
  }, openDirectory: async () => {} });
  const card = ui.element('firstCommand');
  card.querySelector('[data-add-match]').handlers.click();
  card.querySelector('[data-add-match]').handlers.click();
  const rows = card.querySelectorAll('.match-row');
  rows[0].querySelector('[data-match="minLength"]').value = '2';
  const type = rows[1].querySelector('[data-match="type"]');
  type.value = 'regex'; type.handlers.change();
  assert.equal(rows[1].querySelector('[data-match="pattern"]').disabled, false);
  rows[1].querySelector('[data-match="pattern"]').value = '(?i)^hello$';
  ui.element('keywords').value = '运行\nrun\n';
  ui.element('inputEnabled').checked = true;
  ui.element('inputEnabled').handlers.change();
  ui.element('inputPlaceholder').value = '参数';
  ui.element('includeIcon').checked = true;
  await ui.fire('generator', 'submit');
  assert.equal(submitted.includeIcon, true);
  assert.deepEqual(submitted.commands[0].keywords, ['运行', 'run']);
  assert.deepEqual(submitted.commands[0].input, { enabled: true, placeholder: '参数' });
  assert.equal(submitted.commands[0].matches[0].minLength, 2);
  assert.equal(submitted.commands[0].matches[1].pattern, '(?i)^hello$');
  rows[1].querySelector('[data-remove-match]').handlers.click();
  await ui.fire('generator', 'submit');
  assert.equal(submitted.commands[0].matches.length, 1);
});
