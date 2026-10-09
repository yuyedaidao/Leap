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
import sys

COMMANDS = json.loads(${JSON.stringify(JSON.stringify(config))})
request = None
try:
    request = json.loads(sys.stdin.readline())
    if not isinstance(request, dict):
        raise ValueError("请求参数无效。")
    params = request.get("params")
    if (request.get("jsonrpc") != "2.0" or not isinstance(request.get("id"), str)
            or not isinstance(params, dict) or not isinstance(params.get("commandID"), str)
            or params["commandID"] not in COMMANDS or not isinstance(params.get("query"), str)):
        raise ValueError("请求参数无效或未知命令。")
    interaction = COMMANDS[params["commandID"]]
    query = params["query"]
    method = request.get("method")
    conversions = {"upper": query.upper(), "lower": query.lower()}
    # 列表查询不产生副作用；业务动作只能放在明确选择或调用阶段。
    if interaction == "list" and method == "leap.query":
        items = [{"id": "upper", "title": conversions["upper"], "description": "转换为大写"},
                 {"id": "lower", "title": conversions["lower"], "description": "转换为小写"}] if query else []
        result = json.dumps({"items": items}, ensure_ascii=False)
    elif interaction == "list" and method == "leap.select" and isinstance(params.get("itemID"), str) and params["itemID"] in conversions:
        result = conversions[params["itemID"]]
    elif interaction != "list" and method == "leap.invoke":
        result = "hello"
    else:
        raise ValueError("未知请求或条目。")
    response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
except (ValueError, TypeError) as error:
    print(str(error), file=sys.stderr)
    response = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": -32602, "message": str(error)}}
print(json.dumps(response, ensure_ascii=False), flush=True)
`;
  return `'use strict';
const commands = ${JSON.stringify(config)};
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  let request;
  try {
    request = JSON.parse(input.trim());
    const params = request?.params;
    if (request?.jsonrpc !== '2.0' || typeof request.id !== 'string' || !params ||
        typeof params.commandID !== 'string' || !Object.hasOwn(commands, params.commandID) ||
        typeof params.query !== 'string') throw new Error('请求参数无效或未知命令。');
    const interaction = commands[params.commandID];
    const conversions = { upper: params.query.toUpperCase(), lower: params.query.toLowerCase() };
    let result;
    // 查询仅生成候选，选择或调用时才执行业务动作。
    if (interaction === 'list' && request.method === 'leap.query') {
      result = JSON.stringify({ items: params.query ? [
        { id: 'upper', title: conversions.upper, description: '转换为大写' },
        { id: 'lower', title: conversions.lower, description: '转换为小写' },
      ] : [] });
    } else if (interaction === 'list' && request.method === 'leap.select' &&
        typeof params.itemID === 'string' && Object.hasOwn(conversions, params.itemID)) {
      result = conversions[params.itemID];
    } else if (interaction !== 'list' && request.method === 'leap.invoke') {
      result = 'hello';
    } else { throw new Error('未知请求或条目。'); }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');
  } catch (error) {
    console.error(error.message);
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request?.id ?? null,
      error: { code: -32602, message: error.message } }) + '\\n');
  }
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
const removeInput = window.leap.onInputChange(value => { query = value; output.textContent = value; });
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
        : '使用随包运行时，一次 JSON-RPC 请求返回一次同 ID 响应，result 为字符串；日志写标准错误，3 秒内退出。\n') +
      (data.withUI ? '\n网页内嵌宽度跟随宿主，height 包含宿主操作栏并按屏幕裁剪；width 用于旧独立窗口兼容。\n' : '') +
      (data.includeIcon ? '\n可替换 icon.png 为自己的 PNG 图标。\n' : '') +
      '\n匹配规则以宿主 NSRegularExpression 为准，生成前使用 macOS Foundation 校验；修改规则后仍需通过安装校验。修改源文件后重新安装；持久数据不要放在受管副本。\n',
  };
  if (data.withUI) files['index.html'] = webPage();
  // 默认 PNG 是真实文件，勾选图标后生成结果仍能直接安装，无需新增文件选择桥接。
  if (data.includeIcon) files['icon.png'] = require('node:fs').readFileSync(require('node:path').join(__dirname, 'default-icon.png'));
  return files;
}

module.exports = { filesFor };
