# Leap 插件开发指南

适用于 Leap 1.2.0。JavaScript 和 Python 使用统一的会话协议；所有 JavaScript 业务入口由宿主自动注入全局 `leap`。无需 Electron、npm 或手动处理标准输入输出。

## 快速开始

打开 Leap 设置 → 本地插件，进入官方“插件模板生成器”。选择空目录、插件名称、运行时及交互方式，然后生成并安装该目录。生成器不会自动安装插件。

- JavaScript/Python 动作：执行一次，显示返回文字，完成后释放进程。
- JavaScript/Python 原生列表：进入时启动进程，同一会话复用；顶部输入框变化触发查询，宿主绘制列表。
- JavaScript/Python 网页：网页内有 `window.leap`，入口脚本有独立的 `leap`；通过 `invoke` 调用脚本，复用当前会话。
- Shell：系统 zsh 执行前台或后台命令，不使用 JS SDK。

示例见 [数字枚举](../Examples/Plugins/NumberEnumeration/README.md)、[文本转换](../Examples/Plugins/TextConvert/README.md)及[示例索引](../Examples/Plugins/README.md)。

## 插件目录

```text
MyPlugin/
  manifest.json       # 清单
  main.js             # JavaScript 业务入口（或 main.py/main.zsh）
  leap.d.ts           # JS 编辑器类型提示，不是运行时 SDK
  jsconfig.json       # 编辑器检查配置
  index.html          # 网页插件可选
  icon.png            # 可选图标
```

SDK 随应用提供，插件无需复制运行时实现。入口采用 CommonJS，可以 `require('node:fs')` 等 Node 内置模块；网页运行于 WKWebView，不具备 Node.js 或 Electron API。

## manifest.json 参考

下面是网页清单；Python 版本将 `runtime` 改为 `python`、`entry` 改为 `main.py`。

```json
{
  "id": "com.example.leap.hello",
  "name": "Hello 插件",
  "version": "1.0.0",
  "minimumHostVersion": "1.2.0",
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

后文数字枚举使用原生列表：将 `presentation` 改为 `"list"`，将 `input` 改为 `{ "enabled": true, "placeholder": "请输入数字" }`，并删除 `webEntry`/`webWindow`。

| 字段 | 类型 / 必填 | 当前规则与行为 |
| --- | --- | --- |
| `id` | string / 是 | 非空；安装路径只接受字母、数字、`.`、`-`、`_`，不能含连续 `..`。同 ID 安装会更新已有插件。建议使用反向域名形式并保持稳定。 |
| `name` | string / 是 | 去除首尾空白后不能为空；用于插件展示和搜索。 |
| `version` | string / 是 | 去除首尾空白后不能为空；用于安装信任记录。宿主未强制语义版本格式，建议 `1.0.0`。 |
| `minimumHostVersion` | string / 否 | 三段数字版本；不得高于当前宿主1.2.0。新模板显式声明1.2.0。 |
| `runtime` | string / 是 | 只能是 `javascript`、`python`、`shell`。 |
| `entry` | string / 是 | 已存在的目录内相对路径；不得为空、以 `/` 开头或包含 `..` 路径组件。提供实际脚本文件。 |
| `commands` | array / 是 | 至少一个命令；同插件内命令 ID 不得重复。 |
| `commands[].id` | string / 是 | 调用时的命令标识。交互命令必须去除首尾空白后非空；开发时应使用非空稳定值。建议 `<插件 ID>.run`。 |
| `commands[].title` | string / 是 | 显示在搜索结果、最近使用及插件操作栏中；交互命令必须去除首尾空白后非空。 |
| `commands[].mode` | string / 否 | `action`直接执行，`interactive`进入插件会话；未声明模式时，无网页执行动作，有网页打开独立窗口。 |
| `commands[].presentation` | string / 交互模式必填 | `list`或`web`；直接执行不得声明。 |
| `commands[].input` | object / 否 | 交互模式可声明 `enabled`（默认true）及字符串 `placeholder`；列表不得禁用输入。 |
| `commands[].keywords` | array of string / 否 | 非空关键词，补充标题、插件名称、命令ID的现有搜索。 |
| `commands[].matches` | array of object / 否 | 文本匹配规则，见下一节。 |
| `commands[].executionMode` | string / 否 | `foreground` 或 `background`，未声明默认 `foreground`。目前只有 Shell 使用此字段；不会让 JavaScript/Python 变为后台任务。 |
| `webEntry` | string / 否 | 已存在的目录内相对路径，与 `entry` 相同的路径约束；仅 JavaScript/Python 支持；`interactive/web`必须声明。 |
| `webWindow` | object / 否 | 必须同时声明 `webEntry`，宽高均为整数；省略时独立窗口为560 × 360，内嵌网页参考高度600。 |
| `webWindow.width` | integer / 配置尺寸时必填 | 至少 400，单位为 macOS 逻辑点。 |
| `webWindow.height` | integer / 配置尺寸时必填 | 至少 300，单位为 macOS 逻辑点。 |
| `icon` | string / 否 | 已存在的目录内相对路径，扩展名为 PNG、JPG、JPEG 或 ICNS，不区分大小写。 |

独立窗口的宽高包含宿主操作栏，不包含系统标题栏；支持拖动调整大小，重新打开恢复清单尺寸。内嵌网页宽度跟随宿主可用内容区，`webWindow.width`用于独立窗口，`height`作为含70点操作栏的初始内容高度参考并按可用屏幕裁剪。生成器默认800 × 600；未配置尺寸的内嵌网页使用600高度参考，独立窗口使用560 × 360。

未知清单字段目前会被解码器忽略，不会自动产生新能力。模板生成器对 ID、三段数字版本等有更严格的表单校验，那是生成器规则，不是所有手写清单都必须遵循的宿主校验。


## 文本匹配规则

`matches` 让搜索框中的内容直接匹配命令，多个规则满足任意一个即可；命令名称和 `keywords` 搜索仍可使用。

```json
"matches": [{ "type": "regex", "pattern": "^[0-9]+$", "minLength": 1, "maxLength": 1000 }]
```

`type` 为 `text` 时匹配长度范围内的文本，不能声明 `pattern`；`regex` 使用 macOS `NSRegularExpression`，必须提供非空、最多 1000 字符的有效表达式。`minLength` 默认 1，`maxLength` 默认 1000，范围必须满足 `1 ≤ minLength ≤ maxLength ≤ 10000`。正则默认允许局部匹配，需要整段匹配时使用 `^`/`$`。选择命令后，当前搜索内容作为插件初始输入。

## 原生列表：只写业务逻辑

```js
leap.onInputChange(({ text, setList }) => {
  const value = text.trim();
  if (value && !/^[0-9]{1,1000}$/.test(value)) {
    throw new Error('请输入最多 1000 位的非负整数。');
  }
  // 不把长整数转换为 Number，避免精度丢失。
  let remainder = 0;
  for (const digit of value) remainder = (remainder + Number(digit)) % 10;
  setList(Array.from({ length: remainder }, (_, index) => ({
    id: String(index), title: `标题 ${index}`,
  })));
});
leap.onSelect(({ item }) => `已选择：${item.title}`);
```

输入 `123` 得到标题 0 至标题 5；输入 `19` 得到空列表。参数变化时宿主约 16ms 合并连续输入，中文组合输入完成后才发送。上下键选择，Enter 执行，Escape 返回搜索，再按 Escape 收起。

列表最多 100 项，使用 `{ id, title, description? }`。ID 必须非空且唯一，标题必须非空，description 为可选字符串。相同业务条目应使用稳定 ID；仍存在的选中 ID 在更新后保留。

`setList` 可以在回调结束前多次调用。没有调用即完成时显示空列表；业务异常显示错误，下次合法输入可恢复。等待新输入结果期间旧条目不能执行，避免输入和选择串号。

## leap API

注册函数返回取消订阅函数。输入、选择及动作各只能有一个处理器；进入和退出可以有多个监听器。生命周期处理器支持 Promise。

| API | Node.js 入口 | 网页 | 说明 |
| --- | --- | --- | --- |
| `onEnter(callback)` | 是 | 是 | `{ commandID, query, signal }`；初始化会话 |
| `onInputChange(callback)` | 是 | 是 | `{ commandID, text, signal, setList }`；网页的 setList 不可用，网页自行绘制 |
| `onSelect(callback)` | 是 | 否 | `{ commandID, text, item, signal }`；返回字符串或 undefined |
| `onInvoke(callback)` | 是 | 否 | `{ commandID, query, signal }`；处理动作和网页调用 |
| `onExit(callback)` | 是 | 是 | 正常退出清理；异常终止不保证执行 |
| `copyText(text)` | 是 | 是 | Promise，复制文本；不读取剪贴板 |
| `outPlugin()` | 是 | 是 | Promise，结束当前插件会话并返回搜索 |
| `hideMainWindow()` | 是 | 是 | Promise，结束当前会话并隐藏启动器；独立插件窗口结束自身会话 |
| `log(...values)` | 是 | 是 | 调试日志；Node console 也自动写入标准错误 |
| `invoke(commandID, query = '')` | 否 | 是 | Promise，调用本插件清单声明的脚本命令，返回字符串 |
| `onSubmit(callback)` | 否 | 是 | Enter 提交，参数为当前输入字符串 |
| `chooseDirectory()` | 否 | 是 | Promise<string \| null>，原生目录 sheet，取消返回 null |
| `openDirectory(path)` | 否 | 是 | Promise<boolean>，在 Finder 打开当前页面选中的目录或其子目录 |

进入初始化完成后，Node/Python 入口收到一次初始输入事件，包括空字符串。网页 `onEnter` 可迟订阅，并获得最新输入；网页应由 onEnter 初始化自己的界面。

### 异步输入与取消

```js
leap.onInputChange(async ({ text, setList, signal }) => {
  if (!text) { setList([]); return; }
  const response = await fetch('https://example.com/search?q=' + encodeURIComponent(text), { signal });
  if (!response.ok) throw new Error('查询失败。');
  const data = await response.json();
  setList(data.map(item => ({ id: String(item.id), title: item.name })));
});
```

异步工作必须返回 Promise，通常使用 async/await。不要在回调已经返回后才从计时器调用 setList。每次输入的更新函数绑定版本；新输入会取消旧 signal，过期或退出后的更新自动丢弃。宿主只允许一个输入处理任务执行，并保留最新的待处理输入，不无限排队。

业务回调默认 3 秒超时。同步死循环、忽略取消的长期操作会结束会话；请用可取消的异步 I/O 避免阻塞事件循环。选择动作不会因新输入而自动重复执行；用 onSelect/onInvoke 执行明确的业务操作，输入回调只生成候选。

### 动作与复制

```js
leap.onInvoke(async ({ query }) => {
  await leap.copyText(query);
  return '已复制';
});
```

复制仅写入文本。窗口操作先确认调用，再关闭会话；如需多步操作，把退出或隐藏放在最后。onExit 只做清理，不继续调用宿主功能。

多命令插件可在同一处理器中根据 commandID 分派，清单决定是直接动作、列表还是网页。列表选择收到 SDK 当前缓存条目的副本，不需重新解析输入或处理 itemID。

### 网页调用

```html
<script>
let commandID;
let query = '';
window.leap.onEnter(context => {
  commandID = context.commandID;
  query = context.query;
});
window.leap.onInputChange(({ text }) => { query = text; });
window.leap.onSubmit(async text => {
  const result = await window.leap.invoke(commandID, text);
  document.querySelector('output').textContent = result;
});
</script>
```

网页不能直接 require Node 模块。复杂本地操作放到脚本入口，用 invoke 传入业务字符串；业务需要结构化参数时可自行 JSON.stringify/parse，这与 SDK 通信格式无关。

网页不允许导航到插件目录之外。宿主接口只接受当前主页面调用，子框架没有授权。输入事件的参数现在统一为对象，使用 `{ text }` 解构。

目录授权只属于当前页面。只允许打开本页面选择的目录及其子目录，拒绝同名前缀目录和越界符号链接。此限制约束目录桥接，不是 Node/Python 文件系统沙箱。打开 Finder 可能让启动器失焦并结束内嵌会话；已生成文件不受影响。

## Python

Python 与 JS 共用结构化会话协议，宿主入口注入 leap；Python 处理器接收字典，SDK 方法为同步调用。取消信号是 threading.Event，用 is_set() 检查；不要把长时间阻塞操作放在输入处理器中。

```python
def query(context):
    text = context['text']
    context['setList']([{'id': 'upper', 'title': text.upper()}] if text else [])

leap.onInputChange(query)
leap.onSelect(lambda context: context['item']['title'])
leap.onInvoke(lambda context: 'hello')
```

## Shell

Shell 入口使用系统 `/bin/zsh`，命令 ID 来自 `LEAP_COMMAND_ID`。foreground 显示持续输出，可停止；background 启动后收起启动器，输出不展示。

```zsh
#!/bin/zsh
set -eu
case "${LEAP_COMMAND_ID:-}" in
  hello.run) printf '%s\n' 'hello' ;;
  *) printf '%s\n' '未知命令。' >&2; exit 1 ;;
esac
```

Shell 不使用 SDK 的 3 秒回调超时，也不能声明列表或网页交互。停止不是业务回滚，脚本自行启动的其他进程不保证一起停止。

## 安装、更新与安全

安装整个插件目录，在确认信任后复制到 Leap 受管目录。修改源目录后必须重新安装；受管副本发生变化时需要重新确认信任。相同插件 ID 更新已有副本，官方插件 ID 不允许覆盖。

插件代码具有 Node/Python 本地权限，SDK 不构成文件系统沙箱。检查来源和业务校验，避免未确认输入直接用于路径、Shell 命令或网络操作。持久数据不要写入受管副本，更新和卸载会影响该目录。

新示例与模板最低要求 Leap 1.2.0。当前处于开发阶段，已统一替换旧协议；现有开发副本需重新生成或改写入口并重新安装，不保留旧调用通道。

## 调试与内部通信

优先用 leap.log 或 console 记录；宿主日志标识为 com.padding.leap/plugin-session。业务抛错显示中文反馈；超时或崩溃后退出并重新进入，不自动重放可能产生副作用的动作。

内部协议为 UTF-8 逐行 JSON，包含 protocol、type、id，以及事件方法/参数或结构化结果。消息上限 1MB，日志保留最新 64KB；正常通信无需双层 JSON 编码。开发者不得直接写 process.stdout，它是 SDK 保留的协议通道。

交互会话只启动一次进程；退出先取消任务、执行最多 250ms 清理，再终止，必要时强制结束。程序退出时清理宿主创建的进程，不保留后台池。异常终止不保证 onExit 执行，因此不能依赖退出回调完成必要的持久化。

在仓库根目录运行：

```sh
node --test Tests/PluginSDK/*.test.js Tests/NumberEnumeration/*.test.js Tests/PluginTemplateGenerator/*.test.js
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests
```

SDK 使用 uTools 的对象与回调设计作为参考，但不提供 Electron 或全部 uTools API 的兼容实现。

功能测试、性能数据和验证限制见 [SDK 验证记录](PluginSDKValidation.md)。
