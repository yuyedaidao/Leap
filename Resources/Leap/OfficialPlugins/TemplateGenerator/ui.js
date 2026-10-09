'use strict';
const form = document.getElementById('generator');
const fields = document.getElementById('fields');
const choose = document.getElementById('choose');
const generate = document.getElementById('generate');
const runtime = document.getElementById('runtime');
const pluginID = document.getElementById('pluginID');
const openButton = document.getElementById('open');
let busy = false;
let generatedDirectory = '';

function feedback(message, isError = false) {
  const box = document.getElementById('feedback');
  box.hidden = false;
  box.dataset.error = String(isError);
  document.getElementById('status').textContent = message;
  document.getElementById('generatedPath').textContent = generatedDirectory;
  openButton.hidden = !generatedDirectory;
}

const commandCards = [document.getElementById('firstCommand')];
const commandTemplate = commandCards[0].cloneNode(true);
// 模板只复制静态结构，新增命令不会继承用户填入的 ID 或搜索规则。
for (const element of commandTemplate.querySelectorAll('[id]')) element.removeAttribute('id');
commandTemplate.removeAttribute('id');
let nextOrdinal = 2;
const field = (card, name) => card.querySelector(`[data-field="${name}"]`);
function addMatch(card) {
  const row = document.getElementById('matchTemplate').content.firstElementChild.cloneNode(true);
  const type = row.querySelector('[data-match="type"]');
  const pattern = row.querySelector('[data-match="pattern"]');
  type.addEventListener('change', () => {
    const regex = type.value === 'regex';
    row.querySelector('[data-pattern-option]').hidden = !regex;
    pattern.disabled = !regex;
  });
  row.querySelector('[data-remove-match]').addEventListener('click', () => row.remove());
  card.querySelector('[data-matches]').append(row);
}
function bindCard(card) {
  field(card, 'interaction').addEventListener('change', updateRuntime);
  field(card, 'inputEnabled').addEventListener('change', updateRuntime);
  card.querySelector('[data-add-match]').addEventListener('click', () => addMatch(card));
  card.querySelector('[data-remove-command]').addEventListener('click', () => {
    if (busy || commandCards.length === 1) return;
    commandCards.splice(commandCards.indexOf(card), 1);
    card.remove();
    updateRuntime(); updateDefaults();
  });
}
bindCard(commandCards[0]);
document.getElementById('addCommand').addEventListener('click', () => {
  if (busy || choose.disabled) return;
  const card = commandTemplate.cloneNode(true);
  const fallback = window.templateValidation.defaults({ directory: document.getElementById('directory').value,
    id: pluginID.value });
  const usedIDs = new Set(commandCards.map(value => field(value, 'id').value.trim() || field(value, 'id').placeholder));
  while (usedIDs.has(`${fallback.id}.run${nextOrdinal}`)) nextOrdinal++;
  card.dataset.ordinal = String(nextOrdinal++);
  card.querySelector('h3').textContent = `命令 ${card.dataset.ordinal}`;
  document.getElementById('commands').append(card);
  commandCards.push(card);
  bindCard(card); updateRuntime(); updateDefaults();
});
function updateRuntime() {
  const shell = runtime.value === 'shell';
  for (const card of commandCards) {
    const interaction = field(card, 'interaction');
    if (shell) interaction.value = 'action';
    interaction.disabled = shell || busy;
    const mode = interaction.value;
    const execution = field(card, 'executionMode');
    card.querySelector('[data-option="executionMode"]').hidden = !shell;
    execution.disabled = !shell;
    if (!shell) execution.value = 'foreground';
    const enabled = field(card, 'inputEnabled');
    if (mode === 'list') enabled.checked = true;
    if (mode === 'action') enabled.checked = false;
    enabled.disabled = mode !== 'web';
    card.querySelector('[data-option="inputEnabled"]').hidden = mode === 'action';
    const placeholder = field(card, 'placeholder');
    placeholder.disabled = mode === 'action' || !enabled.checked;
    card.querySelector('[data-option="placeholder"]').hidden = placeholder.disabled;
    card.querySelector('[data-remove-command]').disabled = commandCards.length === 1 || busy;
  }
  const web = commandCards.some(card => field(card, 'interaction').value === 'web');
  for (const id of ['width', 'height']) {
    document.getElementById(`${id}Option`).hidden = !web;
    document.getElementById(id).disabled = !web;
  }
  document.getElementById('runtimeHint').textContent = shell
    ? 'Shell 仅支持直接执行，可选择前台或后台；后台输出不显示。'
    : '可混合直接执行、列表和网页命令；JavaScript/Python 不支持后台执行。';
}
function commandsFromForm() {
  return commandCards.map(card => {
    const interaction = field(card, 'interaction').value;
    const command = { id: field(card, 'id').value.trim() || field(card, 'id').placeholder,
      title: field(card, 'title').value.trim() || field(card, 'title').placeholder,
      interaction, executionMode: field(card, 'executionMode').value,
      keywords: field(card, 'keywords').value.split(/\r?\n/).map(value => value.trim()).filter(Boolean),
      matches: [...card.querySelectorAll('.match-row')].map(row => {
        const value = name => row.querySelector(`[data-match="${name}"]`).value;
        const rule = { type: value('type'), minLength: value('minLength'), maxLength: value('maxLength') };
        if (rule.type === 'regex') rule.pattern = value('pattern');
        return rule;
      }) };
    if (interaction !== 'action') command.input = {
      enabled: field(card, 'inputEnabled').checked, placeholder: field(card, 'placeholder').value ||
        (interaction === 'list' ? '输入文本进行大小写转换…' : ''),
    };
    return command;
  });
}

function setBusy(value) {
  busy = value;
  fields.disabled = value;
  generate.disabled = value;
  openButton.disabled = value;
  generate.textContent = value ? '正在生成…' : '生成插件模板';
  if (!value) updateRuntime();
}

function updateDefaults() {
  const fallback = window.templateValidation.defaults({
    directory: document.getElementById('directory').value,
    name: document.getElementById('pluginName').value,
    id: pluginID.value,
  });
  // 默认值只作为占位提示，不覆盖用户输入；提交时共享校验再应用同一规则。
  pluginID.placeholder = window.templateValidation.defaults({
    directory: document.getElementById('directory').value,
  }).id || '选择目录后自动确定';
  for (const card of commandCards) {
    const ordinal = Number(card.dataset.ordinal);
    field(card, 'id').placeholder = fallback.id ? `${fallback.id}.run${ordinal === 1 ? '' : ordinal}` : '选择目录后自动确定';
    field(card, 'title').placeholder = fallback.commandTitle
      ? `${fallback.commandTitle}${ordinal === 1 ? '' : ` ${ordinal}`}` : '默认使用插件名称';
  }
}
pluginID.addEventListener('input', updateDefaults);
document.getElementById('pluginName').addEventListener('input', updateDefaults);
runtime.addEventListener('change', updateRuntime);

choose.addEventListener('click', async () => {
  if (busy || choose.disabled) return;
  choose.disabled = true;
  // 原生对话框单独走宿主桥接，用户选择时间不占用脚本调用超时。
  generate.disabled = true;
  openButton.disabled = true;
  try {
    const directory = await window.leap.chooseDirectory();
    if (directory !== null) {
      document.getElementById('directory').value = directory;
      updateDefaults();
      generatedDirectory = '';
      document.getElementById('feedback').hidden = true;
      openButton.hidden = true;
    }
  } catch (error) { feedback(String(error.message || error), true); }
  finally { choose.disabled = false; generate.disabled = false; openButton.disabled = false; }
});

async function openGenerated() {
  try {
    await window.leap.openDirectory(generatedDirectory);
    feedback('插件模板已生成，已用 Finder 打开。');
  } catch (error) {
    feedback(`插件模板已生成，但打开目录失败：${String(error.message || error)}。可点击“打开目录”重试。`, true);
  }
}

openButton.addEventListener('click', async () => {
  if (busy || !generatedDirectory || openButton.disabled) return;
  openButton.disabled = true;
  try { await openGenerated(); }
  finally { openButton.disabled = false; }
});

form.addEventListener('submit', async event => {
  event.preventDefault();
  if (busy || choose.disabled) return;
  let data;
  try {
    const values = Object.fromEntries(new FormData(form));
    data = window.templateValidation.validate({ ...values, commands: commandsFromForm(),
      includeIcon: document.getElementById('includeIcon').checked });
  } catch (error) { feedback(String(error.message || error), true); return; }
  generatedDirectory = '';
  setBusy(true);
  feedback('正在生成插件文件…');
  try {
    const response = JSON.parse(await window.leap.invoke('template.generate', JSON.stringify(data)));
    if (typeof response.directory !== 'string' || !response.directory.startsWith('/')) throw new Error('插件返回的目录无效。');
    generatedDirectory = response.directory;
    await openGenerated();
  } catch (error) { feedback(String(error.message || error), true); }
  finally { setBusy(false); }
});
updateDefaults();
updateRuntime();
