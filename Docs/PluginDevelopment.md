# Leap 插件开发指南

本文面向使用 JavaScript、Python 或 Shell 开发本地插件的开发者，覆盖创建、安装、运行、网页 UI、宿主桥接和调试。

适用范围：Leap 1.1.0。支持命令级 `mode`、标准列表、内嵌网页与生命周期事件；未声明 `mode` 的旧插件保持原行为。新模板声明 `minimumHostVersion: "1.1.0"`，宿主在安装时校验版本；更早的宿主可能忽略新字段，开发者仍需明确告知最低版本。运行时版本以应用随包资源为准，不依赖用户 PATH 中的 Node.js 或 Python。

## 目录

- [快速入门](#快速入门)
- [插件结构与运行方式](#插件结构与运行方式)
- [manifest.json 参考](#manifestjson-参考)
- [命令交互模式与文本匹配](#命令交互模式与文本匹配)
- [JavaScript 与 Python 运行协议](#javascript-与-python-运行协议)
- [Shell 插件](#shell-插件)
- [网页 UI 开发](#网页-ui-开发)
- [宿主桥接 API](#宿主桥接-api)
- [模板生成器的完整交互流程](#模板生成器的完整交互流程)
- [安装、更新与卸载](#安装更新与卸载)
- [调试与测试](#调试与测试)
- [常见问题](#常见问题)
- [实现与示例索引](#实现与示例索引)

## 快速入门

1. 安装并打开 Leap。“创建插件模板”是官方内置插件，无需另行安装，随应用更新。
2. 在启动器搜索“创建插件模板”，打开生成器。选择一个空目录，可以在原生选择窗口中直接新建文件夹。
3. 填写插件名称，选择 JavaScript、Python 或 Shell，以及“直接执行”“持续输入列表”或“自定义网页 UI”。Shell 仅允许直接执行。
4. 点击“生成插件模板”。成功后 Finder 打开所选目录，模板直接写入该目录，不额外创建子目录。
5. 回到设置，选择新生成的整个目录安装插件。生成器不会自动安装生成结果。
6. 搜索生成的命令。直接执行得到 `hello`；网页 UI 内嵌显示，点击“运行”得到 `hello`；列表模式进入后输入文本，实时显示大小写转换候选，上下键选择并按 Enter 查看反馈。
7. 在源目录修改脚本或网页后，重新选择该目录安装更新，再重新打开插件验证。

生成器支持多命令、关键词、文本/正则匹配、顶部输入配置、Shell 前台/后台、网页尺寸和可选默认图标。生成器拒绝非空目录，包括包含隐藏文件的目录；写入失败只回滚本次创建的文件，保留所选目录。默认值规则见 [生成器说明](../Resources/Leap/OfficialPlugins/TemplateGenerator/README.md)。

也可以手工创建下节的清单和脚本，再按相同流程安装。Leap 执行的是安装时复制的受管副本，修改源文件不会热更新已安装插件。

## 插件结构与运行方式

一个插件至少包含根目录中的 `manifest.json` 和清单声明的脚本入口。网页和图标是可选资源。

```text
MyPlugin/
├── manifest.json
├── main.js           # 或 main.py / main.zsh
├── index.html        # 可选网页入口
├── ui.js             # 可选网页逻辑
├── style.css         # 可选样式
└── icon.png          # 可选图标
```

| 插件类型 | 选择启动器命令后 | 输入与输出 |
| --- | --- | --- |
| JavaScript/Python，`mode: action` | 执行一次脚本，显示文本；共享 `webEntry` 不影响此命令 | 单次 `leap.invoke` |
| JavaScript/Python，`interactive/list` | 接管参数输入，显示宿主列表 | `leap.query` 查询、`leap.select` 选择 |
| JavaScript/Python，`interactive/web` | 输入框下方展示网页，不自动执行脚本 | 网页桥接及生命周期事件 |
| 未声明 `mode` 的旧 JavaScript/Python | 无网页直接执行，有网页打开独立窗口 | 原有调用协议 |
| Shell，`foreground` | 启动脚本，显示持续输出，可停止 | `LEAP_COMMAND_ID` 与标准输出/错误 |
| Shell，`background` | 启动脚本后收起启动器 | `LEAP_COMMAND_ID`；输出不显示 |

同一插件的命令共用一个脚本入口。脚本依据命令 ID 分派业务；网页只能调用本插件清单中声明的命令。当前没有跨插件调用或脚本流式结果接口；新内嵌网页可接收宿主的进入、输入、提交及退出事件。

## manifest.json 参考

下面的清单可以与后文 JavaScript 示例及网页示例一起使用；Python 版本将 `runtime` 改为 `python`、`entry` 改为 `main.py`。

```json
{
  "id": "com.example.leap.hello",
  "name": "Hello 插件",
  "version": "1.0.0",
  "minimumHostVersion": "1.1.0",
  "runtime": "javascript",
  "entry": "main.js",
  "commands": [
    { "id": "hello.run", "title": "运行 Hello", "mode": "interactive",
      "presentation": "web", "input": { "enabled": false } }
  ],
  "webEntry": "index.html",
  "webWindow": { "width": 800, "height": 600 }
}
```

要改为直接执行插件，将命令改为 `mode: "action"`，删除命令的 `presentation`/`input`；没有其他网页命令时也可删除 `webEntry`/`webWindow`。

| 字段 | 类型 / 必填 | 当前规则与行为 |
| --- | --- | --- |
| `id` | string / 是 | 非空；安装路径只接受字母、数字、`.`、`-`、`_`，不能含连续 `..`。同 ID 安装会更新已有插件。建议使用反向域名形式并保持稳定。 |
| `name` | string / 是 | 去除首尾空白后不能为空；用于插件展示和搜索。 |
| `version` | string / 是 | 去除首尾空白后不能为空；用于安装信任记录。宿主未强制语义版本格式，建议 `1.0.0`。 |
| `minimumHostVersion` | string / 否 | 三段数字版本；不得高于当前宿主1.1.0。新交互模板显式声明1.1.0。 |
| `runtime` | string / 是 | 只能是 `javascript`、`python`、`shell`。 |
| `entry` | string / 是 | 已存在的目录内相对路径；不得为空、以 `/` 开头或包含 `..` 路径组件。提供实际脚本文件。 |
| `commands` | array / 是 | 至少一个命令；同插件内命令 ID 不得重复。 |
| `commands[].id` | string / 是 | 调用时的命令标识。交互命令必须去除首尾空白后非空；旧模式与动作保留既有校验，开发时应使用非空稳定值。建议 `<插件 ID>.run`。 |
| `commands[].title` | string / 是 | 显示在搜索结果、最近使用及插件操作栏中；交互命令必须去除首尾空白后非空。 |
| `commands[].mode` | string / 否 | `action`直接执行，`interactive`进入插件会话；缺省保持旧行为。 |
| `commands[].presentation` | string / 交互模式必填 | `list`或`web`；直接执行和旧模式不得声明。 |
| `commands[].input` | object / 否 | 交互模式可声明 `enabled`（默认true）及字符串 `placeholder`；列表不得禁用输入。 |
| `commands[].keywords` | array of string / 否 | 非空关键词，补充标题、插件名称、命令ID的现有搜索。 |
| `commands[].matches` | array of object / 否 | 文本匹配规则，见下一节。 |
| `commands[].executionMode` | string / 否 | `foreground` 或 `background`，未声明默认 `foreground`。目前只有 Shell 使用此字段；不会让 JavaScript/Python 变为后台任务。 |
| `webEntry` | string / 否 | 已存在的目录内相对路径，与 `entry` 相同的路径约束；仅 JavaScript/Python 支持；`interactive/web`必须声明。 |
| `webWindow` | object / 否 | 必须同时声明 `webEntry`，宽高均为整数；省略时旧独立窗口为560 × 360，新内嵌网页参考高度600。 |
| `webWindow.width` | integer / 配置尺寸时必填 | 至少 400，单位为 macOS 逻辑点。 |
| `webWindow.height` | integer / 配置尺寸时必填 | 至少 300，单位为 macOS 逻辑点。 |
| `icon` | string / 否 | 已存在的目录内相对路径，扩展名为 PNG、JPG、JPEG 或 ICNS，不区分大小写。 |

旧独立窗口的宽高包含宿主操作栏，不包含系统标题栏；支持拖动调整大小，重新打开恢复清单尺寸。新内嵌网页宽度跟随宿主可用内容区，`webWindow.width`保留用于独立窗口兼容，`height`作为含70点操作栏的初始内容高度参考并按可用屏幕裁剪。生成器默认800 × 600；未配置尺寸的新内嵌网页使用600高度参考，旧独立窗口使用560 × 360。

未知清单字段目前会被解码器忽略，不会自动产生新能力。模板生成器对 ID、三段数字版本等有更严格的表单校验，那是生成器规则，不是所有手写清单都必须遵循的宿主校验。

## 命令交互模式与文本匹配

配置作用于每个命令，同一个插件可同时提供直接动作、列表和网页。`executionMode`仍仅控制Shell前台/后台；JavaScript/Python的交互命令不允许`background`，Shell不支持`interactive`。

### Enter、输入和返回

- 全局搜索中按Enter：`action`执行一次，`interactive`进入并锁定当前命令。
- 关键词进入时参数清空；只有内容匹配且没有关键词匹配时，原始文本成为初始参数。
- 列表模式的输入以200ms防抖触发查询，输入法组合期间不查询，最多一个查询调用及一个最新待查询输入；过期结果不覆盖界面。
- 列表中上下键移动选择，Enter或点击执行选中项；查询未完成或动作执行中不重复选择，动作执行期间保留参数输入，新查询等动作完成后运行；旧动作反馈不覆盖新参数的结果。
- 网页启用输入时，顶部参数更新发送事件；禁用时只显示插件标识和返回按钮，网页使用自己的表单。
- 返回按钮或Escape恢复进入前的全局搜索，再按Escape收起；原生目录选择sheet和输入法组合优先处理Escape。
- 失焦收起或快捷键重新唤起时结束当前会话，重新唤起默认全局搜索。关闭会话取消列表请求但不保证业务副作用回滚。

列表命令示例（放入清单的commands中）：

```json
{
  "id": "text.convert",
  "title": "文本转换",
  "mode": "interactive",
  "presentation": "list",
  "keywords": ["转换", "convert"],
  "input": { "enabled": true, "placeholder": "输入文本…" },
  "matches": [{ "type": "text", "minLength": 1, "maxLength": 1000 }]
}
```

### 内容匹配

`matches`是规则数组，任一匹配就产生候选；宿主不会在匹配阶段执行插件。关键词候选排在内容候选前，同一命令不会重复展示。

| 字段 | 规则 |
| --- | --- |
| `type` | `text`匹配任意非空文本，`regex`匹配正则文本 |
| `pattern` | 仅regex必填；采用macOS Foundation正则语法，直接写模式，不使用`/模式/i`形式，忽略大小写可写`(?i)`；最多1000字符 |
| `minLength` | 正整数，默认1 |
| `maxLength` | 不小于minLength且不超过10000，默认1000 |

例如仅推荐处理HTTP网址的命令：

```json
{"type":"regex","pattern":"^https?://[^\\s]+$","minLength":8,"maxLength":1000}
```

长度按Swift字符计数，不是UTF-8字节数。规则在插件索引刷新时编译；无效正则在安装时拒绝。限制输入长度不保证复杂正则没有性能问题，应使用简单、有边界的模式。第一版不支持图片、文件或活动窗口匹配。

### 列表查询与选择协议

复用JSON-RPC单次进程和字符串result，新增两种method；不通过`leap.invoke`自动运行列表查询。

```json
{"jsonrpc":"2.0","id":"query-1","method":"leap.query","params":{"commandID":"text.convert","query":"Hello"}}
```

查询result是下列对象序列化后的字符串，而不是直接返回对象：

```json
{"items":[{"id":"upper","title":"HELLO","description":"转换为大写"},{"id":"lower","title":"hello","description":"转换为小写"}]}
```

`items`最多100项；`id`和`title`必须是非空字符串，ID在这次列表中唯一且应在相同业务对象上保持稳定；`description`可省略。空结果使用`{"items":[]}`。条目不包含宿主可执行脚本或隐式动作，必须由插件显式处理选择：

```json
{"jsonrpc":"2.0","id":"select-1","method":"leap.select","params":{"commandID":"text.convert","query":"Hello","itemID":"upper"}}
```

选择返回普通反馈字符串，保持在插件内；用户可以继续输入。非法结果显示错误，修改输入可恢复。查询应无副作用，文件写入等动作放在明确选择或网页按钮调用中。完整JavaScript入口见[TextConvert](../Examples/Plugins/TextConvert/main.js)，生成器也提供Python列表模板。

## JavaScript 与 Python 运行协议

### 请求、响应与生命周期

Leap 每次调用启动一个新的随包 Node.js 或 Python 进程，并通过标准输入发送一条 UTF-8 JSON-RPC 2.0 请求，末尾有换行，然后关闭标准输入。

```json
{"jsonrpc":"2.0","id":"example-request-1","method":"leap.invoke","params":{"commandID":"hello.run","query":"来自网页"}}
```

- `id` 是宿主生成的字符串，响应必须原样返回，不要自行生成或转换类型。
- `commandID` 是本次调用命令；纯脚本的 `query` 是启动器当前查询文本，网页调用的 `query` 是传入的字符串。
- 当前一次调用只接收一个结果，没有进程复用、持久内存状态、批量请求或流式结果协议；网页生命周期事件不通过脚本进程传递。
- 默认限时 3 秒，包含进程启动与脚本执行；进程必须在期限内退出，仅输出响应但继续运行也会超时。超时会尝试终止该进程。
- 宿主没有为 JavaScript/Python 设置插件工作目录。读取随插件资源时使用 Node 的 `__dirname` 或 Python 的 `Path(__file__).parent`，不要依赖相对当前工作目录的路径。

成功响应的 `result` 必须是字符串：

```json
{"jsonrpc":"2.0","id":"example-request-1","result":"hello"}
```

业务需要返回对象时先序列化为字符串，网页再 `JSON.parse`，不要直接让 `result` 等于对象：

```json
{"jsonrpc":"2.0","id":"example-request-1","result":"{\"message\":\"hello\"}"}
```

失败响应使用整数 `code` 和字符串 `message`，宿主目前向调用方展示错误信息，不提供桥接层结构化错误码：

```json
{"jsonrpc":"2.0","id":"example-request-1","error":{"code":-32602,"message":"请求参数无效。"}}
```

单次请求和标准输出各限制1MB；日志最多保留64KB，超出的日志继续排空但不保留。标准输出只写一行响应 JSON，末尾换行；调试日志写到标准错误。宿主读取标准输出第一行，并要求进程退出码为 0；非零退出会优先按进程失败处理，即使已经输出 JSON-RPC 错误响应。不要输出大段日志或大结果，当前协议面向短时、小文本调用，没有大数据传输接口。

### JavaScript 最小入口：main.js

与上面的 `hello.run` 清单配套。Node 标准库可直接使用，无需 SDK 或第三方依赖。

```javascript
'use strict';

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  let request;
  try {
    request = JSON.parse(input.trim());
    if (request?.jsonrpc !== '2.0' || typeof request.id !== 'string' ||
        request.method !== 'leap.invoke' || request.params?.commandID !== 'hello.run' ||
        typeof request.params.query !== 'string') {
      throw new Error('请求参数无效。');
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: 'hello' }) + '\n');
  } catch (error) {
    const message = String(error.message || error);
    // 标准输出属于协议，日志必须走标准错误。
    console.error(message);
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request?.id ?? null,
      error: { code: -32602, message } }) + '\n');
  }
});
```

真实插件应继续校验 `query` 中的业务数据，在写入文件、发起网络请求前检查边界，并将其他业务错误映射为合适的错误响应。示例中的错误码仅用于请求参数错误。无法解析请求、无法取得 ID 时示例返回 `null`，不符合宿主的字符串 ID 响应要求；正常宿主请求不会出现此情况，这用于直接调试时报告错误。

### Python 最小入口：main.py

```python
import json
import sys

request = None
try:
    request = json.loads(sys.stdin.readline())
    if not isinstance(request, dict):
        raise ValueError("请求参数无效。")
    params = request.get("params")
    if (request.get("jsonrpc") != "2.0" or not isinstance(request.get("id"), str)
            or request.get("method") != "leap.invoke" or not isinstance(params, dict)
            or params.get("commandID") != "hello.run" or not isinstance(params.get("query"), str)):
        raise ValueError("请求参数无效。")
    response = {"jsonrpc": "2.0", "id": request["id"], "result": "hello"}
except (ValueError, TypeError) as error:
    # 标准错误用于日志，标准输出保留给单条协议响应。
    print(str(error), file=sys.stderr)
    response = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": -32602, "message": str(error)}}
print(json.dumps(response, ensure_ascii=False), flush=True)
```

当前仓库随包运行时路径为 `node-24.21.0/bin/node` 和 `python-3.14.7/Versions/3.14/bin/python3.14`，它们是当前构建资源，不是插件 API 的固定版本承诺。宿主不会自动执行 `npm install` 或 `pip install`；最小插件优先用标准库。需要依赖时自行提供兼容当前运行时的文件，避免依赖开发机环境。

## Shell 插件

Shell 使用系统 `/bin/zsh`，不走 JavaScript/Python 的 JSON-RPC，也不能声明 `webEntry` 或 `webWindow`。

```json
{
  "id": "com.example.leap.shell",
  "name": "Shell Hello",
  "version": "1.0.0",
  "runtime": "shell",
  "entry": "main.zsh",
  "commands": [{ "id": "hello.run", "title": "Shell Hello", "executionMode": "foreground" }]
}
```

入口 `main.zsh`：

```zsh
#!/bin/zsh
set -eu

# 命令来自环境变量，不把启动器查询文本当成 Shell 源码执行。
case "${LEAP_COMMAND_ID:-}" in
  hello.run) printf '%s\n' 'hello' ;;
  *) printf '%s\n' '未知命令。' >&2; exit 1 ;;
esac
```

- 工作目录为受管插件目录；环境继承宿主，并增加 `LEAP_COMMAND_ID`。当前没有为 Shell 定义查询文本参数或环境变量。
- 宿主通过 `/bin/zsh <入口路径>` 运行，不要求入口文件具有可执行权限，也不会自动打开 Terminal。
- 前台模式合并显示标准输出和标准错误，执行结束后显示结果；非零退出显示失败，运行中可用宿主“停止”按钮终止脚本进程。
- 后台模式启动成功后收起启动器，丢弃输出；失败记录在宿主日志中，没有前台结果页面或后台任务控制桥接。
- Shell 不使用 JSON-RPC 的 3 秒超时。停止脚本不是业务回滚，也不保证脚本启动的所有子进程都被停止；文件修改需要插件自行保证完整性。

多命令入口参考 [ShellCommands](../Examples/Plugins/ShellCommands)。

## 网页 UI 开发

界面用普通 HTML/CSS/JavaScript 编写，表单、按钮和结果展示通过 DOM 操作。宿主用 `WKWebView` 加载受管插件目录内的 `webEntry`，在文档开始加载时向主框架注入只读的 `window.leap` 对象。

网页脚本与 Node.js 脚本是两个环境：网页不能直接使用 `require('node:fs')`，需要通过 `invoke` 请求入口脚本完成文件操作。UI 层负责收集输入与反馈，脚本层负责业务校验和副作用；不要认为网页校验能代替脚本校验。

### 可直接运行的 index.html

将此页与上面的 Hello 清单及 JavaScript 或 Python 入口放在同一目录。按钮点击后调用脚本，使用 `textContent` 展示返回文本，避免把不可信输出当 HTML 插入。

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hello 插件</title>
  <style>
    body { font: 15px system-ui; padding: 24px; color-scheme: light dark; }
    button { padding: 10px 18px; }
    output { display: block; margin-top: 16px; white-space: pre-wrap; overflow-wrap: anywhere; }
  </style>
</head>
<body>
  <h1>Hello</h1>
  <button id="run" type="button">运行</button>
  <output id="result" role="status" aria-live="polite"></output>
  <script>
    const button = document.getElementById('run');
    const result = document.getElementById('result');
    button.addEventListener('click', async () => {
      if (button.disabled) return;
      button.disabled = true;
      result.textContent = '正在运行…';
      try {
        if (typeof window.leap?.invoke !== 'function') throw new Error('请在支持桥接的 Leap 中打开此页。');
        result.textContent = await window.leap.invoke('hello.run', '');
      } catch (error) {
        result.textContent = String(error.message || error);
      } finally {
        button.disabled = false;
      }
    });
  </script>
</body>
</html>
```

### 页面、导航与窗口边界

- 在普通浏览器直接打开页面不会注入 `window.leap`。开发时可以模拟桥接测试页面逻辑，真实调用必须在 Leap 内验证。
- 本地资源的 WebView 读取范围为受管插件目录。导航策略只允许该目录内的 `file:` 页面，远程页面导航会被取消；这不等于对所有网络请求实施沙箱，不能据此推断 `fetch` 或远程子资源的行为。
- 桥接默认只注入主框架，不应依赖 iframe 中存在 `window.leap`。目录接口还要求调用来源为清单声明的原始主页面；导航到其他本地 HTML 后不能调用目录接口。
- 同一插件的网页命令共用`webEntry`。新内嵌命令通过`onEnter`取得commandID/query；旧独立窗口不发送进入上下文。页面可以依据命令ID展示不同功能。
- 命令标题显示在宿主操作栏；旧独立窗口提供“关闭”，新内嵌界面提供“返回搜索”。旧独立窗口中，没有原生选择sheet时Escape关闭窗口；新内嵌网页中Escape返回搜索；sheet打开时由系统处理取消。
- 关闭窗口释放网页及目录授权；重新打开不能沿用此前选择的目录授权。关闭网页也不应被当作脚本调用取消或文件写入回滚。
- 用响应式布局适应窗口拖动，保持键盘操作、标签和状态反馈可用。当前没有网页设置窗口尺寸或关闭窗口的桥接，初始尺寸通过清单配置。

## 宿主桥接 API

只调用公开的 `window.leap` 方法，不直接使用 `window.webkit.messageHandlers`；内部消息通道属于宿主实现细节。

下面的签名用于说明类型，不表示当前提供 TypeScript SDK：

```typescript
interface LeapBridge {
  invoke(commandID: string, query?: string): Promise<string>;
  chooseDirectory(): Promise<string | null>;
  openDirectory(path: string): Promise<boolean>;
  onEnter(callback: (context: { commandID: string; query: string }) => void): () => void;
  onInputChange(callback: (query: string) => void): () => void;
  onSubmit(callback: (query: string) => void): () => void;
  onExit(callback: () => void): () => void;
}
```

`invoke`、`chooseDirectory`、`openDirectory`均为异步调用。失败时 Promise 拒绝，用 `try/catch` 处理，显示错误可以用 `String(error.message || error)`。不要依赖错误对象的具体类或解析中文错误文本作业务分支。

### invoke(commandID, query = '')

| 项目 | 约定 |
| --- | --- |
| `commandID` | 字符串，必须属于当前插件清单的 `commands`，不能调用其他插件命令。 |
| `query` | 字符串，省略为 `''`；传入对象、数字或 `null` 会被拒绝，不会自动 JSON 序列化。 |
| 返回 | `Promise<string>`；值就是脚本响应中的 `result`，没有额外响应包装。 |
| 失败 | 参数无效、未声明命令、运行时缺失、进程失败、超时、响应无效或脚本业务错误。 |

简单文本：

```javascript
try {
  const text = await window.leap.invoke('hello.run', '');
  document.getElementById('result').textContent = text;
} catch (error) {
  document.getElementById('result').textContent = String(error.message || error);
}
```

结构化数据：页面用 `JSON.stringify(data)` 作为 `query`；脚本解析和校验后执行操作，将返回对象再 `JSON.stringify` 为 `result`；页面对返回字符串 `JSON.parse` 并检查所需字段。解析失败也应进入错误反馈，而不是假定脚本输出总是正确。

宿主没有为普通 `invoke` 去重或提供取消接口。页面应禁用执行按钮避免重复操作，脚本有副作用时仍需防止重复写入和并发冲突。

### chooseDirectory()

无参数，打开附着在当前插件窗口上的原生目录选择 sheet：只能选一个目录，允许在选择窗口中新建目录。

- 确认后返回规范化、解析符号链接后的绝对路径字符串。
- 用户取消返回 `null`，不是错误；保持页面原有输入即可。窗口不可用时也可能返回 `null`。
- 用户选择目录的等待不占用脚本的 3 秒超时；不应通过入口脚本弹出长期等待的选择窗口。
- 同一网页实例同时重复选择会拒绝第二个调用，提示“目录选择窗口已经打开。”；无效目录也会拒绝。
- 成功选择替换当前实例的目录授权；取消不会撤销之前成功选择的授权。

```javascript
try {
  const path = await window.leap.chooseDirectory();
  if (path !== null) document.getElementById('directory').value = path;
} catch (error) {
  document.getElementById('result').textContent = String(error.message || error);
}
```

### openDirectory(path)

在 Finder 打开目录。`path` 必须是存在的绝对目录路径，不得含 NUL 字符；成功返回 `true`，失败拒绝 Promise，不用 `false` 表示失败。

授权来自同一网页实例此前的成功 `chooseDirectory()`，只允许所选目录或其后代目录。宿主解析符号链接并按路径组件比较，因此 `/tmp/work-other` 不属于 `/tmp/work`，指向所选目录外的符号链接也会被拒绝。未选择目录、越界、目录不存在及 Finder 打开失败都会拒绝。

选择另一个目录后旧授权失效，关闭网页后授权被释放。路径字符串本身不是授权凭据；不能通过把旧路径保存到本地再打开新页面来恢复授权。

```javascript
try {
  const path = await window.leap.chooseDirectory();
  if (path !== null) await window.leap.openDirectory(path);
} catch (error) {
  document.getElementById('result').textContent = String(error.message || error);
}
```

### 网页生命周期事件

事件只针对新内嵌网页会话，订阅返回取消监听函数：

| API | 参数与时机 |
| --- | --- |
| `onEnter(callback)` | `{commandID, query}`；迟订阅也会异步收到当前上下文 |
| `onInputChange(callback)` | 已确认的参数字符串；输入法组合期间不发送 |
| `onSubmit(callback)` | 顶部参数框按Enter时传入当前字符串；网页表单自己的提交仍由DOM处理 |
| `onExit(callback)` | 返回或隐藏时通知清理监听；不等待异步回调完成，不用于关键业务保存 |

```javascript
let commandID;
const output = document.getElementById('result');
const removeEnter = window.leap.onEnter(context => {
  commandID = context.commandID;
  output.textContent = context.query;
});
const removeInput = window.leap.onInputChange(query => { output.textContent = query; });
const removeSubmit = window.leap.onSubmit(async query => {
  try { output.textContent = await window.leap.invoke(commandID, query); }
  catch (error) { output.textContent = String(error.message || error); }
});
window.leap.onExit(() => { removeEnter(); removeInput(); removeSubmit(); });
```

输入事件不会替网页自动调用脚本；网页自行决定查询或提交行为，并处理并发和错误。页面加载期间的输入变化和提交保留最新值，加载完成后送达。事件回调中的同步异常记录到网页控制台，不影响其他监听器。界面只有一个顶部参数框，没有插件修改全局搜索或任意宿主状态的接口。

### 能力边界

当前桥接提供脚本调用、目录选择和 Finder 打开目录；网页自己的表单、按钮、弹层用 DOM 实现。没有通用文件选择/保存、剪贴板、通知、Leap 主界面控制或其他应用 UI 自动化桥接。

目录授权只约束宿主的 `openDirectory`，不是 Node/Python/Shell 的文件系统沙箱，也不会阻止脚本直接操作其他路径。脚本按当前进程和系统权限执行；插件开发者必须在有副作用的入口校验业务数据，安装者需要检查插件内容。当前没有基于清单的细粒度权限声明机制。

## 模板生成器的完整交互流程

[TemplateGenerator](../Resources/Leap/OfficialPlugins/TemplateGenerator) 是三个异步桥接方法共同使用的实例，自身清单为interactive/web并关闭顶部参数输入。以下是其调用流程；复用时保留该示例的清单、`main.js`、`validation.js`、`templates.js`，页面中的字段和事件绑定见 [ui.js](../Resources/Leap/OfficialPlugins/TemplateGenerator/ui.js)。`template.generate` 是这个插件的命令，不是每个插件都能调用的宿主服务。

```text
用户填写表单
  → chooseDirectory：选择保存目录，取消则保留输入
  → 页面校验并禁用按钮，展示生成状态
  → invoke('template.generate', JSON.stringify(data))
  → Node 校验输入、检查空目录、独占创建文件
  → result 字符串包含 directory 与 files
  → 页面解析并校验 directory
  → openDirectory(directory)：Finder 打开目录
  → 打开失败保留生成结果，仅重试打开目录
```

传给生成器命令的业务对象例如：

```json
{
  "directory": "/absolute/path/to/empty-directory",
  "name": "我的插件",
  "version": "1.0.0",
  "runtime": "javascript",
  "interaction": "web",
  "width": 800,
  "height": 600
}
```

成功打开 Finder 会使启动器失焦并结束内嵌会话；生成文件保留在所选目录。打开失败时页面仍保留生成结果，可仅重试打开目录。该目录必须由当前页面先选择，才能在生成后通过桥接打开。`id`、`commandID`、`commandTitle` 可以留空或省略，生成器按自己的默认规则补齐。新增 `commands` 数组支持多命令，其字段包括 `id`、`title`、`interaction`、`executionMode`、`input`、`keywords`、`matches`；提供数组时优先于旧单命令参数，空数组报错。`minimumHostVersion` 默认且当前仅支持 `1.1.0`，`includeIcon` 默认 false，勾选后生成可替换的 `icon.png`。正则在任何文件写入前通过 macOS Foundation 批量校验。脚本返回对象形如 `{ "directory": "<实际目录>", "files": ["manifest.json", "main.js", "README.md", "index.html"] }`，但通过桥接接收的是这个对象的 JSON 字符串。

实现时保留以下处理：

| 阶段 | 页面行为 | 脚本 / 宿主行为 |
| --- | --- | --- |
| 选择目录 | 禁用相关按钮；取消保留输入，成功选择清空旧生成结果；结束后恢复按钮 | 主页面验证、单个选择 sheet、更新会话授权 |
| 提交 | 共享校验通过才调用；检查忙碌状态，防重复提交 | 脚本再次校验，检查目录存在、可写且为空 |
| 写入 | 展示“正在生成” | 使用独占创建避免覆盖；失败只清理本次创建且未被替换的文件 |
| 接收结果 | JSON 解析，验证 `directory` 是绝对路径字符串 | 返回字符串结果 |
| 打开目录 | 生成成功与 Finder 失败分别反馈；保留路径，允许仅重试打开 | 验证会话授权与真实路径，失败拒绝 Promise |
| 完成 / 失败 | `finally` 恢复表单可用状态，用 `textContent` 显示信息 | 错误写入标准错误，协议错误返回 JSON-RPC |

不要在 Finder 打开失败时重新执行生成：文件已经生成，重复生成会因目录非空而失败。不要用清空整个目录作为错误回滚。

## 安装、更新与卸载

官方模板生成器从应用包资源直接加载，设置中标记“官方内置”，不能单独卸载或用本地同 ID 插件覆盖。旧版手动安装的同 ID 副本保留但不执行；随包资源损坏时不会回退执行旧副本。其他本地插件仍按以下流程管理。

- 安装入口为设置 → 本地插件 → 安装本地插件，选择包含 `manifest.json` 的整个目录。宿主检查清单与资源，首次安装需要确认；版本或受检查内容变化时再次确认。
- 默认受管目录为 `~/Library/Application Support/Leap/Plugins/<插件 ID>/`，信任记录在相邻 `Trust/` 中。移动源目录不影响安装副本。
- 更新时保持相同插件 ID，在源目录修改，再重新选择源目录安装；同 ID 会替换整个受管副本。换 ID 会创建另一个插件，而不是更新原插件。
- 不要把用户生成的数据或持久状态放在受管副本里：更新会替换、卸载会删除该副本。由插件设计独立数据位置及其生命周期。
- 不要直接修改受管副本调试。宿主会对受检查内容与信任记录进行比对，不匹配的插件不会进入命令列表；也不要把该比对当作完整脚本沙箱或安全审计。
- 卸载删除受管副本与信任记录，不删除源目录，也不自动清理脚本在其他位置创建的文件。
- 当前没有自动重新加载源文件的开发模式。更新后关闭并重新打开网页插件，确保页面与脚本使用同一次安装的版本。

## 调试与测试

### 直接验证脚本协议

以下命令从仓库根目录执行。先将上文入口示例保存到 `/tmp/LeapHello/main.js`、`main.py`、`main.zsh`；路径可换为自己的开发目录。直接运行只能验证脚本，不会模拟 Leap 网页桥接。

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":"manual-1","method":"leap.invoke","params":{"commandID":"hello.run","query":""}}' \
  | Resources/Leap/Runtimes/node-24.21.0/bin/node /tmp/LeapHello/main.js

printf '%s\n' '{"jsonrpc":"2.0","id":"manual-1","method":"leap.invoke","params":{"commandID":"hello.run","query":""}}' \
  | Resources/Leap/Runtimes/python-3.14.7/Versions/3.14/bin/python3.14 /tmp/LeapHello/main.py

LEAP_COMMAND_ID=hello.run /bin/zsh /tmp/LeapHello/main.zsh
```

JavaScript/Python 预期返回一行 JSON：`jsonrpc` 为 `2.0`、`id` 为 `manual-1`、`result` 为 `hello`，进程退出码为 0。将命令 ID 改为未支持的值，应得到同 ID 的 `error` 响应和标准错误日志。Shell 正常输出 `hello`；未知命令应记录标准错误并非零退出。

Node 使用 `console.error`，Python 使用 `print(..., file=sys.stderr)` 记录调试信息。成功调用的标准错误不会自动成为网页结果；需要时直接运行入口检查。宿主错误可在 macOS Console 中筛选 Leap，相关日志标签包含 `json-rpc`、`launcher-model`、`plugin-directory` 和 `shell-script`。网页错误应同时给出可见反馈，不仅写入控制台。

### 仓库已有测试

从仓库根目录运行生成器的 Node 测试，无需安装 npm 依赖：

```sh
Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginTemplateGenerator/*.test.js
```

原生清单、目录会话和七种生成模板的集成测试：

```sh
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' \
  -only-testing:LeapTests/PluginInteractionManifestTests \
  -only-testing:LeapTests/PluginListSessionTests \
  -only-testing:LeapTests/PluginInteractionProcessTests \
  -only-testing:LeapTests/PluginWebWindowManifestTests \
  -only-testing:LeapTests/PluginDirectorySessionTests \
  -only-testing:LeapTests/PluginTemplateGeneratorTests
```

真实网页桥接、原生选择窗口、Finder 与生成结果运行的 UI 测试会启动应用并操作界面，需在可交互的 macOS 会话中单独运行：

```sh
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' \
  -only-testing:LeapUITests/PluginInteractionUITests \
  -only-testing:LeapUITests/PluginTemplateGeneratorUITests \
  -only-testing:LeapUITests/PluginWebWindowUITests
```

如果工程文件尚未生成，先运行 `tuist generate`。测试面向本仓库开发，不要求第三方插件用户安装 Xcode。

### 自己的插件至少验证这些场景

| 场景 | 预期 |
| --- | --- |
| 安装 → 搜索 → 调用 | 命令可见，结果符合协议；网页需点击操作后调用 |
| 未知命令、非法业务输入 | 不产生副作用，返回可见错误 |
| 入口失败、错误响应、超时 | 页面恢复可操作，不保持永久忙碌状态 |
| 选择取消、重复点击 | 取消保留输入，避免第二次选择或重复写入 |
| 目录未授权、越界、符号链接越界 | `openDirectory` 拒绝；合法目录与子目录可以打开 |
| 生成成功但 Finder 失败 | 文件与结果路径保留，仅重试打开 |
| 窗口调整、键盘操作、关闭后重开 | 页面能适应尺寸，状态可读，重新选择后才使用目录授权 |
| 修改源文件并重新安装 | 新版本生效；更新与卸载不误删源目录或外部用户数据 |

## 常见问题

| 现象 | 检查与处理 |
| --- | --- |
| `window.leap` 不存在 | 是否在普通浏览器或 iframe 中运行；是否使用具有相应桥接的新版本 Leap。 |
| 网页请求了未声明的插件命令 | 对照当前已安装清单的 `commands[].id`，不要跨插件调用。 |
| 网页调用参数无效 | `commandID` 和 `query` 必须是字符串；对象先 JSON 序列化。 |
| 插件返回无效 JSON-RPC 响应 | 标准输出第一行是否被日志污染；`result` 是否为字符串；响应格式是否正确。 |
| 响应与当前请求不匹配 | 响应 ID 必须是请求中的原字符串。 |
| 插件响应超时 | 3 秒内是否退出；是否等待用户操作、网络或遗留定时器。 |
| 随包运行时不可用 | 使用包含运行时资源的 Leap 构建；安装系统解释器不会自动修复随包路径。 |
| 修改源码但结果没变 | 重新安装源目录更新受管副本，关闭并重新打开网页。 |
| 只能打开当前页面选择的目录及其子目录 | 当前页面是否成功选择过目录；是否更换了选择；路径或符号链接是否越界。 |
| 目录接口只允许当前插件主页面调用 | 从原始 `webEntry` 主框架调用，不要从 iframe 或导航后的其他页面调用。 |
| 生成后无法打开目录 | 保留生成结果，检查目录仍存在且属于当前授权，使用“打开目录”重试。 |
| Shell 没有网页 / 后台没有输出 | Shell 不支持 `webEntry`；后台输出不显示，需自行设计日志。 |

## 实现与示例索引

| 参考 | 用途 |
| --- | --- |
| [插件示例入口](../Examples/Plugins/README.md) | 按插件类型选择可运行示例 |
| [TextConvert](../Examples/Plugins/TextConvert/README.md) | 持续输入列表与查询/选择协议 |
| [TemplateGenerator](../Resources/Leap/OfficialPlugins/TemplateGenerator/README.md) | 三种桥接、共享校验、文件生成与重试 |
| [WebEcho 页面](../Examples/Plugins/WebEcho/index.html) | 简单网页调用脚本 |
| [PluginManifest](../Sources/LeapCore/PluginManifest.swift) | 清单字段及实际校验 |
| [PluginWebView](../Sources/Leap/PluginWebView.swift) | 公开桥接注入、页面加载及消息处理 |
| [PluginDirectorySession](../Sources/LeapCore/PluginDirectorySession.swift) | 目录授权生命周期与路径边界 |
| [JSONRPCProcessRunner](../Sources/LeapCore/JSONRPCProcessRunner.swift) | JSON-RPC 输入输出、超时与错误处理 |
| [PluginScriptExecutor](../Sources/LeapCore/PluginScriptExecutor.swift) | 随包运行时定位与脚本启动 |
| [ShellScriptExecutor](../Sources/LeapCore/ShellScriptExecutor.swift) | Shell 环境、输出与进程控制 |
| [PluginWebWindowController](../Sources/Leap/PluginWebWindowController.swift) | 窗口尺寸、关闭与网页释放 |
| [PluginInstaller](../Sources/LeapCore/PluginInstaller.swift) | 受管复制、安装确认、更新与卸载 |

后续新增或修改插件能力时，同步更新本指南的清单、桥接签名、示例与错误说明；不要仅更新内部设计文档。
