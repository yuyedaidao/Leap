# 前台 Shell 插件输出体验改造

## Context

运行本地前台 Shell 插件 `JProject`（`/Users/wyq/Work/Project/2026/LeapPlugins_Local/JProject`，`runtime: shell`、`executionMode: foreground`、脚本只 `printf 'hello\n'`），实际观感有两个问题：

1. **看不到任何输出**。面板只多出一行「JProject 已结束」，下面一块空白底框，`hello` 从未出现。
2. **执行完仍停在搜索列表/最近使用界面**。查询词和结果列表（或最近使用宫格）继续占据面板主体，执行结果被挤在最底部，和"刚跑完一条命令"这件事完全不匹配。

### 根因（已确认）

- `Sources/Leap/LauncherView.swift` 的 `LauncherInvocationFeedback` 里输出区是 `ScrollView { Text(...) }.frame(maxHeight: 220)`。外层 `VStack` 没有确定高度，`ScrollView` 在滚动轴上无固有高度，被分配到 0，于是只剩 `.padding(10)` 的空白底框 —— 「有框没字」。
- 出结果后 `LauncherContent`（搜索结果 / 最近使用）照样渲染：`LauncherView.body` 只在 `model.interaction != nil` 时切到插件视图，前台 Shell 走 `else` 分支，永远和列表并排。
- 面板高度由 `onGeometryChange` → `LauncherPanelController.resize(..., keepWithinScreen:)` 驱动，非交互态传 `false`，内容变高时只向下伸展，底边可推出屏幕外。

### 目标形态（含用户确认的取舍）

前台 Shell 运行**就是一次"进入插件"**，与可交互插件保持操作习惯一致：

- 头部：查询框换成插件标签（图标 + 插件名 / 命令名 + ✕），固定在启动框左侧表示激活状态；Shell 清单禁止 `input`/`matches`，所以此时**没有可输入的控件**，键盘输入不落到后台搜索（等价于交互插件 `inputEnabled: false` 的现状）。要继续搜索先按 ✕ 退出。
- 主体：整块换成运行视图（状态行 + 输出区），搜索结果/最近使用宫格隐藏。
- 运行中：状态行显示「正在运行 …」+「停止」按钮，输出增量刷新并自动滚到底。
- 自然结束：保持打开，输出留在原地供查看/复制；按 ✕ 回到搜索，按 Esc 收起面板。
- Esc / 失焦 / 切设置等任何收起面板的动作：**终止正在运行的前台脚本**。
- 后台脚本行为不变（启动后收起启动器、不展示输出）。

## Approach

1. **修输出塌陷**：把 `.shellOutput` 这一坨抽成独立 `ShellRunOutput` 视图，用 `onGeometryChange` 量出 `Text` 实际高度，给 `ScrollView` 显式 `.frame(height: min(max(contentHeight, 44), 320))`。既有自动滚动、`textSelection`、64KB 尾部截断逻辑保持不变。
2. **路由切换**：`LauncherView.body` 增加一个分支 —— `model.interaction` 优先，其次 `model.showsShellRun`（`invocationState` 是 `.shellOutput` 时为真）时渲染头标签 + `ShellRunOutput`，其余仍是现有 `LauncherContent` + 反馈条。
3. **头部复用**：把 `PluginInteractionTag` 的「图标 + 名称 / 标题 + ✕」抽成 `PluginHeaderTag`（保留 `plugin.activeName`、`plugin.activeTitle`、`plugin.backButton` 标识与 `.help`），`PluginInteractionTag` 变成它的薄包装（继续传 `showsLoading`），Shell 头部直接用 `PluginHeaderTag`。
4. **退出与终止**：模型新增 `exitShellRun()`（cancel + 清 `foregroundShellTask` + `invocationState = .idle` + `requestSearchFocus()`），✕ 调它；`prepareForPresentation()` 里也 cancel 一次，避免重新唤起时留下孤儿任务。面板收起统一走 `LauncherPanel` 覆写 `orderOut(_:)` 的钩子终止脚本，覆盖 Esc、失焦、设置按钮三条路径。
5. **窗口不越界**：`createPanel` 里 `keepWithinScreen` 在前台 Shell 视图时为 `true`，让窗口向上让位而不是把输出推出屏幕。

## Files to modify

- `Sources/Leap/LauncherView.swift`：`body` 路由、`LauncherSearchHeader` 增加 Shell 标签分支、新增 `ShellRunOutput`、删除旧 `.shellOutput` 内联分支。
- `Sources/Leap/PluginInteractionView.swift`：抽出 `PluginHeaderTag`，`PluginInteractionTag` 改为包装。
- `Sources/Leap/LauncherModel.swift`：新增 `showsShellRun`、`exitShellRun()`；`prepareForPresentation()` 终止前台任务；`activateListShortcut` 在前台 Shell 视图下不再响应数字快捷键（避免操作隐藏的列表项）。
- `Sources/Leap/LauncherPanelController.swift`：`keepWithinScreen` 条件扩展；`LauncherPanel` 覆写 `orderOut(_:)` 调新钩子。
- `Docs/PluginDevelopment.md`（Shell 一节，约 234 行）：说明前台输出改为独立运行视图、✕/Esc 与终止语义。
- `Tests/LeapUITests/LeapUITests.swift`（或新文件 `ShellRunUITests.swift`）：新增前台 Shell 端到端用例。

## Reuse

- `PluginInteractionTag`（`Sources/Leap/PluginInteractionView.swift`）：现成的「插件名 + 关闭按钮」标签，抽取复用而不是新写。
- `LauncherModel.stopForegroundShell()` / `ShellScriptTask.cancel()`：停止能力已存在。
- `LauncherModel.limitedShellOutput(_:)`：64KB 保留尾部截断已实现。
- `LauncherPanelController.resize(_:toContentHeight:keepWithinScreen:)`：屏幕内让位逻辑已实现，只是没对前台 Shell 开启。
- `onGeometryChange` 量高度的写法在 `Sources/Leap/NativeResultList.swift` 已有同样用法。

## Steps

- [x] `ShellRunOutput` 视图：状态行（运行中/已结束）+ 停止按钮 + 量高 ScrollView 输出区，保留 `launcher.shellOutput`、`launcher.stopShellButton` 标识。
- [x] `LauncherView.body`：`interaction` → 交互视图；否则 `.shellOutput` → 着头标签 + `ShellRunOutput`；否则现状。
- [x] `LauncherSearchHeader`：新增可选 `shellCommand: PluginCommandDescriptor?`，命中时渲染 `PluginHeaderTag` + `Spacer`，不渲染 TextField 与参数输入。
- [x] `PluginHeaderTag` 抽取，`PluginInteractionTag` 改为包装，保持标识与 `.help` 文案不变（交互插件 UI 测试不能被破坏）。
- [x] `LauncherModel`：加 `showsShellRun`、`exitShellRun()`；`prepareForPresentation()` 终止前台任务；`activateListShortcut` 在前台 Shell 视图下返回 `false`。
- [x] `LauncherPanelController`：`keepWithinScreen` 扩展；`orderOut` 覆写挂 `shellRunDidHide` 钩子调 `model.stopForegroundShell()`。
- [x] `Docs/PluginDevelopment.md` Shell 一节同步新交互。
- [x] 新增 UI 测试：临时目录装一个 `runtime: .shell` 插件（`run.zsh` 打印 `hello-from-shell`），搜索 → Return → 断言 `launcher.shellOutput` 内出现 `hello-from-shell`、`plugin.activeName` 存在、`launcher.searchField` 与搜索结果列表不再存在；点 `plugin.backButton` 后搜索框恢复。
- [x] 构建 + `swiftlint` + `xcodebuild test -only-testing:LeapTests/LauncherShellTests` + 新增 UI 测试 + 手动安装 `JProject` 按上面的目标形态验收。

## Verification

1. `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`。
2. `swiftlint`。
3. `xcodebuild test ... -only-testing:LeapTests/LauncherShellTests`（执行器行为未变，回归）。
4. `xcodebuild test ... -only-testing:LeapUITests/ShellRunUITests`（新增用例，同时确认 `PluginInteractionUITests` 未因标签抽取回归）。
5. 手动：重新安装 `/Users/wyq/Work/Project/2026/LeapPlugins_Local/JProject`，搜索 `JProject` 回车 →
   - 列表消失，头部显示 `JProject` 标签，输出区显示 `hello`；
   - 运行中滚动到底、停止按钮可终止；
   - ✕ 回到搜索且输出清空；
   - 再跑一次后 Esc 收起面板，脚本被终止（可把脚本改成 `sleep 30` 验证）。
6. 长输出用例：临时把脚本改成循环打印 1000 行，确认输出区高 320 封顶、可滚动、尾部保留。

## 不做（本次范围外）

- 不给前台 Shell 增加退出码/失败状态的可视化区分（现状把错误文案追加进输出即可），也不加"复制输出"按钮。
- 不改后台 Shell 的行为（仍不展示输出）。
