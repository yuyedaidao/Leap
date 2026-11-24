# Launcher 搜索栏右侧按钮：有结果时显示选中项图标并可点击执行

## Context

`LauncherSearchHeader` 右侧 40pt 圆形按钮只负责打开设置，位置显眼但信息量低（"喧宾夺主"）。

定下的方向（用户明确）：

- 搜索有结果、且其中一项被选中时，按钮内容换成该项的图标；
- 此时点击按钮 = 点击/回车执行选中项；
- 其他时候按钮保持现在的样子、现在的行为（打开设置）。

这样按钮在搜索态承担真实功能，同时非搜索态仍是原来的设置入口。

## 现状要点（已确认）

- 位置：`Sources/Leap/LauncherView.swift` 的私有 `LauncherSearchHeader`。
- 选中项解析已存在：`LauncherView.hasSearchResults`、`model.selectedSearchResultID`，`activateSelectedItem()` 是唯一执行路径（回车与列表点击都走 `model.activate(item)`）。
- `LauncherItemIcon(item:)` 已存在（应用走 `NSWorkspace` + `SystemApplicationIconCache`，插件走 `CommandIcon`），直接复用。
- 按钮当前结构：`ZStack { Circle().fill(.quaternary); Image("LauncherSettingsIcon").frame(width: iWidth) }`，`iWidth = bWidth * 0.62`；action 为 `exitInteraction()` + `showSettings()`；标识 `launcher.settingsButton`、label `设置`。
- 标识被 5 个 UI 测试文件使用；已核对：这些点击全部发生在空查询、无搜索结果时，所以只要**预览态单独用新标识**，现有测试无需改动。

## Approach

单按钮，按状态分支；只增加"有预览"这一支：

| 状态 | 内容 | 点击 | 标识 / label |
| --- | --- | --- | --- |
| `hasSearchResults` 且有选中项（`interaction == nil && shellCommand == nil`） | `LauncherItemIcon(item: previewItem)` | 执行选中项（复用 `activateSelectedItem()`，与回车一致） | `launcher.selectedItemButton` / `打开 <title>` |
| 其余（空输入、无结果、插件交互、前台 Shell） | 现有 `LauncherSettingsIcon` | 现状：`exitInteraction()` + `showSettings()` | `launcher.settingsButton` / `设置` |

细节：

- `previewItem`：`hasSearchResults` 且无插件交互/前台 Shell 时取选中的结果项，选中 ID 缺失时回退到结果首项（与 `activateSelectedItem()` 一致）。
- 图标沿用同一 `iWidth`（40 × 0.62 ≈ 25pt）居中，`Circle().fill(.quaternary)` 背景保留，两态不跳动。
- 不新增动画：选中项随方向键变化时直接换图。
- 预览态点击执行后，走既有 `model.activate` 链路（应用启动会隐藏面板、插件会进入交互或输出），无需额外收尾。

## Files to modify

- `Sources/Leap/LauncherView.swift`
  - `LauncherView`：加 `previewItem` 计算属性；向 header 传 `previewItem` 与 `activateSelectedItem`。
  - `LauncherSearchHeader`：加 `var previewItem: LauncherItem? = nil`、`var activateSelected: () -> Void = {}`（给默认值，现有预览调用点不受影响）；按钮 label 增预览分支；action 增预览分支；`accessibilityIdentifier` / `accessibilityLabel` 按上表动态取值。
- `Tests/LeapUITests/LeapUITests.swift`
  - 新增一条用例：安装 fixture 插件 → 输入 `result.1` → 点击 `launcher.selectedItemButton` → 断言 `launcher.pluginResult` 出现（照抄同文件既有用例的 fixture 安装与断言写法）。

## Reuse

- `LauncherItemIcon`（`LauncherView.swift`）：应用与插件图标渲染。
- `hasSearchResults`、`activateSelectedItem()`（`LauncherView.swift`）：选中项判定与执行路径，预览态点击直接调用。
- `SystemApplicationIconCache`：方向键切换时的图标缓存已存在。
- `LeapUITests` 中既有 fixture 插件安装 + `launcher.pluginResult` 断言写法：新用例直接复用。

## 分支

从 `main`（当前 `6f53293`，工作区干净）新建 `feat/launcher-selection-preview`，本次全部改动只落在这条分支上，不直接改 `main`。

## Steps

- [x] `git switch -c feat/launcher-selection-preview`。
- [x] `LauncherView` 加 `previewItem`，传入 header 与 `activateSelectedItem`。
- [x] `LauncherSearchHeader` 加两个带默认值的参数。
- [x] 按钮 label 增加预览分支（复用 `LauncherItemIcon` 与现有 `iWidth`）。
- [x] 按钮 action 增加预览分支：有预览则执行选中项，否则保持现状。
- [x] 动态 `accessibilityIdentifier` / `accessibilityLabel`。
- [x] 新增 UI 用例覆盖"点预览按钮执行选中项"。
- [x] `swiftlint` + 构建 + `LeapTests` 单测。
- [x] 出预览图（结果态 / 空输入态），用户确认视觉后再提交。

## Verification

1. `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
2. `swiftlint`
3. `xcodebuild test ... -only-testing:LeapTests`
4. UI 测试：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapUITests`（重点看 `SettingsWindowUITests`、`PluginInteractionUITests` 里所有 `launcher.settingsButton` 用法仍通过）
5. 手动检查：
   - 输入关键字有结果 → 按钮显示首条结果图标；↑↓ 切换时图标同步变化。
   - 点击按钮 → 启动的应用/插件与点击该行、按回车完全一致。
   - 输入无结果的关键字 → 按钮回到设置图标，点击打开设置。
   - 清空输入（最近使用网格）→ 保持设置图标与设置行为。
   - 插件交互 / 前台 Shell 运行 → 保持设置图标，点击仍是"退出交互 + 打开设置"。
6. 视觉确认后才在该分支上 `git commit`；确认前不合并、不推送 `main`。
