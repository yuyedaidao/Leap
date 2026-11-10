# 插件之间互相调用（runPlugin）

## Context

当前插件只能调用宿主接口，`leap.invoke` 仅限**同一个插件**内的命令（`Sources/Leap/PluginInteractionSession.swift:105` 会校验 `command.manifest.commands`）。用户希望一个插件能启动另一个插件的命令，并且希望这是 Leap 的原生能力、通过 HostAPI 暴露给插件。

已确认的产品约束（用户明确选择）：

- **不做权限/白名单**：任意插件可调用任意已启用插件的命令，不新增清单字段，不加信任提示。
- **语义是「启动」而不是 RPC**：参数（`query`）透传给目标命令，返回值只有成功/失败，不返回目标的数据。
- **不做嵌套深度限制**：由插件作者负责。

因此 `runPlugin` 等价于「像用户从启动器选中目标命令一样启动它」：调用成功后调用方插件会话结束，目标插件接管界面。

## Approach

新增宿主接口 `runPlugin(pluginID, commandID, query?)`，返回 `true` 表示已找到目标命令并启动。

关键取舍：**回复先写回调用方，再启动目标**。`LauncherModel.activate` 会 `closeActionSession()` / `exitInteraction()` 关闭调用方会话，而 `PluginProcessSession.send` 在会话关闭后不再写回复（`Sources/LeapCore/PluginProcessSession.swift:220` 的 `guard !closed`），若在宿主调用内直接启动，调用方永远拿不到 `true`。仓库已有正解：`onHostReply` 是在回复写完后才触发的回调（`PluginProcessSession.swift:328`，注释「回复已提交给 WebKit 后才关闭页面」），因此：

1. 宿主调用阶段只做校验 + 登记；
2. `onHostReply("runPlugin")` 触发时才真正 `activate` 目标命令。

不做的事：不加权限模型、不加清单字段、不等待目标执行结果、不新增会话槽位（同一时刻仍只有一个面板会话）。

## Files to modify

- `Sources/LeapCore/PluginHostAPI.swift` — 新接口 + 回调属性
- `Sources/Leap/LauncherModel.swift` — 目标登记、`activate` 的 query 覆盖、action 回复后的启动
- `Sources/Leap/PluginInteractionSession.swift` — 回复后统一入口 `didReplyHostCall`
- `Sources/Leap/PluginWebView.swift` — 网页调用回复后走同一入口
- `Sources/Leap/LauncherPanelController.swift` — 展示面板并启动（复用 `notificationCommand` 的写法）
- `Resources/Leap/PluginSDK/host-api.js` — JS/Node/网页共用包装
- `Resources/Leap/PluginSDK/bootstrap.py` — Python 包装
- `Resources/Leap/PluginSDK/leap.d.ts` — 类型声明（会被模板生成器自动带入新插件，见 `Resources/Leap/OfficialPlugins/TemplateGenerator/templates.js:132`）
- `Docs/PluginDevelopment.md` — HostAPI 表格与说明
- `Docs/PluginSDKValidation.md` — 验证记录
- `Tests/LeapTests/PluginHostAPITests.swift`、`Tests/LeapTests/LauncherShellTests.swift`、`Tests/PluginSDK/host-api.test.js`

## Reuse

- `PluginHostAPI.notificationCommand`（`Sources/LeapCore/PluginHostAPI.swift:32`）+ `Sources/Leap/LauncherPanelController.swift:38-46` 的「reloadPlugins → 查命令 → present → activate」写法，直接照搬。
- `onHostReply` 机制（`Sources/LeapCore/PluginProcessSession.swift:328`, `Sources/Leap/LauncherModel.swift:438`, `Sources/Leap/PluginInteractionSession.swift:54`, `Sources/Leap/PluginWebView.swift:237`）——已有的「回复后再动作」通道。
- `string(_:_:)` 参数校验（`PluginHostAPI.swift:104`）、`PluginSessionError.plugin(_:)` 错误。
- `host-api.js` 里 `showNotification` 的多参数包装写法（本地 `TypeError` 校验 + `invoke`）。
- `LeapCommonSDK` 声明位置（`Resources/Leap/PluginSDK/leap.d.ts:53-90`）。
- 网页侧 `...createHostSDK(host)`（`Resources/Leap/PluginSDK/web.js:76`）会自动带上新方法，无需改 `web.js`。

## Steps

- [x] `PluginHostAPI`：新增
      `public var runPlugin: ((_ pluginID: String, _ commandID: String, _ query: String) -> Bool)?`
      并在 `execute` 的 switch（`PluginHostAPI.swift:211`）里加 case：
      ```swift
      case "runPlugin":
          let pluginID = try string(params, "pluginID")
          let commandID = try string(params, "commandID")
          if let query = params["query"], query.string == nil {
              throw PluginSessionError.plugin("参数 query 必须为字符串。")
          }
          guard runPlugin?(pluginID, commandID, params["query"]?.string ?? "") == true else {
              throw PluginSessionError.plugin("未找到可启动的插件命令：\(pluginID)/\(commandID)。")
          }
      ```
      （放在 `check(context)` 之后自然覆盖；返回值落到函数末尾的 `.bool(true)`。）
- [x] `LauncherModel`：
      - 新增 `private var pendingPluginRun: (command: PluginCommandDescriptor, query: String)?`
      - `func preparePluginRun(pluginID:commandID:query:) -> Bool`：在 `commands` 里查 `pluginID`/`commandID`，命中则登记并返回 `true`（插件已停用时查不到，天然拒绝）
      - `func activatePendingPluginRun()`：取出登记项并调用新的 `pluginRunRequested?(command, query)` 回调
      - `var pluginRunRequested: ((PluginCommandDescriptor, String) -> Void)?`
      - `activate(_ command: PluginCommandDescriptor, query overrideQuery: String? = nil)`：`let launchQuery = overrideQuery ?? self.query`，交互式命令用 `overrideQuery ?? (原 initialInput 表达式)` 作为 `initialInput`，动作/Shell 走 `run(command, query: launchQuery)`；`previousSearch` 仍用启动器当前 `query`
      - action 会话的 `onHostReply`（`LauncherModel.swift:438`）内加 `else if method == "runPlugin" { self.activatePendingPluginRun() }`
- [x] `PluginInteractionSession`（原生列表与网页共用）：
      - `var onPluginRun: (() -> Void)?`
      - `func didReplyHostCall(_ method: String)`：`guard isActive`；`runPlugin` → `onPluginRun?()`；其余交给 `hostAction?(method)`
      - 自身的 `onHostReply` 改为调用 `didReplyHostCall(method)`
- [x] `PluginWebView.swift:237`：把 `interaction.hostAction?(method)` 换成 `interaction.didReplyHostCall(method)`（该处注释已保证回复先提交给 WebKit）
- [x] `LauncherPanelController.init`：
      - `model.hostAPI?.runPlugin = { [weak model] pluginID, commandID, query in model?.preparePluginRun(pluginID: pluginID, commandID: commandID, query: query) ?? false }`
      - `model.pluginRunRequested = { [weak self] command, query in self?.present(); self?.model.activate(command, query: query) }`
- [x] `LauncherModel.activate` 的交互式分支与 `makeWebSession` 里设置 `session.onPluginRun = { [weak self] in self?.activatePendingPluginRun() }`
- [x] SDK：
      - `host-api.js` 增加
        ```js
        runPlugin: (pluginID, commandID, query = '') => {
          if (typeof pluginID !== 'string' || !pluginID || typeof commandID !== 'string' || !commandID || typeof query !== 'string') {
            return Promise.reject(new TypeError('插件 ID、命令 ID 必须为非空字符串，参数必须为字符串。'));
          }
          return invoke('runPlugin', { pluginID, commandID, query });
        },
        ```
      - `leap.d.ts` 的 `LeapCommonSDK` 增加 `runPlugin(pluginID: string, commandID: string, query?: string): Promise<boolean>;`
      - `bootstrap.py` 增加 `run_plugin(plugin_id, command_id, query="")`（本地类型校验后 `host_call("runPlugin", {...})`），并 `leap.runPlugin = run_plugin`
- [x] 文档：`Docs/PluginDevelopment.md` HostAPI 表格加一行 `| 启动其他插件 | runPlugin(pluginID, commandID, query?) | 启动已启用插件的命令并透传查询；返回是否启动 |`，并补一段说明：调用后当前插件会话结束（等同用户选中目标命令）、目标找不到时抛错、不返回目标的数据、没有嵌套限制；`Docs/PluginSDKValidation.md` 追加本次接口的验证记录
- [x] 测试：
      - `Tests/LeapTests/PluginHostAPITests.swift`：① `runPlugin` 回调收到 `(pluginID, commandID, query)` 且返回 `.bool(true)`；② 未设置回调 / 回调返回 `false` 时抛「未找到可启动的插件命令」；③ `query` 非字符串时报参数错误
      - `Tests/LeapTests/LauncherShellTests.swift`：用现有 fixture 命令覆盖 `preparePluginRun` 命中/未命中，以及 `activatePendingPluginRun` 会回传登记的 `(command, query)`
      - `Tests/PluginSDK/host-api.test.js`：`runPlugin` 参数透传 + 三类 `TypeError`
- [x] 更新 `README`/Skill 不需要：`skills/leap-plugin-development/SKILL.md` 只在需要时补一句（可选）

## Verification

```bash
swiftlint
xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests
Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginSDK/host-api.test.js
```

手工验证：写一个临时 JS 动作插件（或改 `Examples/Plugins/HostAPI` 的副本），命令体 `await leap.runPlugin('另一个插件 ID', '命令 ID', '参数')`，再：

1. 从启动器运行它 → 目标插件被启动，当前插件退出；
2. 传入不存在的插件 ID / 命令 ID → 报「未找到可启动的插件命令」；
3. 目标为原生列表插件 → 列表以传入的 query 作为初始输入；
4. 目标为网页插件 / Shell 插件 → 窗口打开、后台脚本启动，均不报错；
5. 从网页插件窗口调用 → 启动器面板展示目标命令（网页窗口保持原状，已知且可接受）。

## 已知限制

- 调用即接管：目标命令启动时调用方会话被关闭，`runPlugin` 之后不应再有依赖返回值的逻辑（补齐 `true` 已尽力保证，但调用方通常会被替换）。
- 网页插件窗口作为调用方时，目标命令在启动器面板中打开，网页窗口不会被自动关闭。
- 无权限模型与嵌套限制（按用户要求）。
