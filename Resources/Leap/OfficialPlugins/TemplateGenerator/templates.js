'use strict';

function scriptFor(runtime, commands) {
  // 配置作为数据序列化，不能把用户填写的 ID 拼成可执行代码。
  const config = Object.fromEntries(commands.map(command => [command.id, command.interaction]));
  if (runtime === 'shell') {
    const ids = commands.map(command => `'${command.id}'`).join('|');
    return `#!/bin/zsh
set -eu
# 所有命令共用入口，未知 ID 必须失败，避免误执行业务动作。
case "\${LEAP_COMMAND_ID:-}" in
  ${ids}) printf '%s\\n' 'hello' ;;
  *) printf '%s\\n' '未知命令。' >&2; exit 1 ;;
esac
`;
  }
  if (runtime === 'python') return `import json

COMMANDS = json.loads(${JSON.stringify(JSON.stringify(config))})

def query(context):
    if COMMANDS.get(context["commandID"]) != "list":
        context["setList"]([])
        return
    text = context["text"]
    context["setList"]([
        {"id": "upper", "title": text.upper(), "description": "转换为大写"},
        {"id": "lower", "title": text.lower(), "description": "转换为小写"},
    ] if text else [])

def invoke(context):
    if context["commandID"] not in COMMANDS or COMMANDS[context["commandID"]] == "list":
        raise ValueError("未知动作命令。")
    return "hello"

leap.onInputChange(query)
leap.onSelect(lambda context: context["item"]["title"])
leap.onInvoke(invoke)
`;
  return `'use strict';
const commands = ${JSON.stringify(config)};
leap.onInputChange(({ commandID, text, setList }) => {
  if (!Object.hasOwn(commands, commandID) || commands[commandID] !== 'list') {
    // 网页无需原生列表；其输入仍通过网页事件送达。
    setList([]); return;
  }
  setList(text ? [
    { id: 'upper', title: text.toUpperCase(), description: '转换为大写' },
    { id: 'lower', title: text.toLowerCase(), description: '转换为小写' },
  ] : []);
});
leap.onSelect(({ item }) => item.title);
leap.onInvoke(({ commandID }) => {
  if (!Object.hasOwn(commands, commandID) || commands[commandID] === 'list') throw new Error('未知动作命令。');
  return 'hello';
});
`;

}

function webPage() {
  return `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>插件界面</title>
<style>body{font:15px system-ui;padding:24px;color-scheme:light dark}button{padding:10px 18px}output{display:block;margin-top:16px;white-space:pre-wrap}</style>
</head><body>
<h1>Hello</h1><p>点击按钮调用当前插件命令。</p>
<button id="invoke" disabled>运行</button><output id="result" role="status" aria-live="polite"></output>
<script>
let commandID;
let query = '';
let active = false;
const button = document.getElementById('invoke');
const output = document.getElementById('result');
async function invoke() {
  if (!active || button.disabled) return;
  button.disabled = true;
  try { const result = await window.leap.invoke(commandID, query); if (active) output.textContent = result; }
  catch (error) { if (active) output.textContent = String(error.message || error); }
  finally { if (active) button.disabled = false; }
}
const removeEnter = window.leap.onEnter(context => {
  commandID = context.commandID;
  query = context.query;
  active = true;
  button.disabled = false;
  output.textContent = query;
});
const removeInput = window.leap.onInputChange(({ text }) => { query = text; output.textContent = text; });
const removeSubmit = window.leap.onSubmit(value => { query = value; return invoke(); });
button.addEventListener('click', invoke);
window.leap.onExit(() => {
  active = false;
  button.disabled = true;
  removeEnter(); removeInput(); removeSubmit();
});
</script></body></html>
`;
}

function filesFor(data) {
  const entry = { javascript: 'main.js', python: 'main.py', shell: 'main.zsh' }[data.runtime];
  const commands = data.commands.map(({ interaction, executionMode, ...command }) => {
    if (interaction === 'action') return { ...command, mode: 'action', executionMode };
    return { ...command, mode: 'interactive', presentation: interaction };
  });
  const manifest = { id: data.id, name: data.name, version: data.version,
    minimumHostVersion: data.minimumHostVersion, runtime: data.runtime, entry, commands };
  if (data.withUI) {
    manifest.webEntry = 'index.html';
    manifest.webWindow = { width: data.width, height: data.height };
  }
  if (data.includeIcon) manifest.icon = 'icon.png';
  const files = {
    'manifest.json': JSON.stringify(manifest, null, 2) + '\n',
    [entry]: scriptFor(data.runtime, data.commands),
    'README.md': `# ${data.name}\n\n版本：${data.version}，要求 Leap ${data.minimumHostVersion} 或以上。\n\n` +
      `在 Leap 设置 → 本地插件 → 安装本地插件中选择本目录并确认安装。${entry} 按命令 ID 分派请求。\n\n` +
      data.commands.map(command => `- ${command.title}（${command.id}）：${command.interaction}，${command.executionMode}`).join('\n') +
      '\n\n直接执行和网页按钮返回 hello；列表查询返回大小写转换候选，选择后返回转换结果。网页通过 onEnter 获取当前命令，通过输入和提交事件接收顶部参数，退出时清理监听。\n\n' +
      (data.runtime === 'shell' ? '使用系统 zsh，通过 LEAP_COMMAND_ID 传递命令；后台输出不显示。\n'
        : '宿主注入 leap；交互会话复用进程，退出即释放，动作结果直接返回字符串。日志使用 leap.log；业务回调限时 3 秒，宿主调用等待另计，每个事件累计最多 60 秒。\n') +
      (data.withUI ? '\n当前生成器创建内嵌网页，宽度跟随启动器；默认宽度仅用于独立窗口。内嵌网页默认高度包含宿主操作栏；独立窗口默认高度为网页内容高度，不包含系统标题栏。尺寸按可用屏幕裁剪。独立窗口可拖动调整大小，重新打开恢复默认尺寸。要使用独立窗口，手动省略网页命令的 mode、presentation、input，同时保留 webEntry 和 webWindow。\n' : '') +
      (data.includeIcon ? '\n可替换 icon.png 为自己的 PNG 图标。\n' : '') +
      '\n匹配规则以宿主 NSRegularExpression 为准，生成前使用 macOS Foundation 校验；修改规则后仍需通过安装校验。修改源文件后重新安装；持久数据不要放在受管副本。\n',
  };
  if (data.withUI) files['index.html'] = webPage();
  if (data.runtime === 'javascript') {
    files['leap.d.ts'] = require('node:fs').readFileSync(require('node:path').join(__dirname, '../../PluginSDK/leap.d.ts'), 'utf8');
    files['jsconfig.json'] = JSON.stringify({ compilerOptions: { checkJs: true, target: 'ES2022' },
      include: ['**/*.js', 'leap.d.ts'] }, null, 2) + '\n';
  }
  // 默认 PNG 是真实文件，勾选图标后生成结果仍能直接安装，无需新增文件选择桥接。
  if (data.includeIcon) files['icon.png'] = require('node:fs').readFileSync(require('node:path').join(__dirname, 'default-icon.png'));
  return files;
}

module.exports = { filesFor };
