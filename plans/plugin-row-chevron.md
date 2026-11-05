# 插件列表行：把详情箭头移到最右

## Context

插件启用/禁用改动后，设置页插件列表每行变成 `[图标+文案+spacer+箭头] [启用开关] [管理菜单]`，详情箭头（`chevron.right`）落在开关左侧，看起来像附属于开关而不是「点击查看详情」。

没有设计上的理由：箭头一直写在详情 `Button` 的 label 内部（`Sources/Leap/PluginSettingsPage.swift:307`），本轮新增的 `Toggle` 和原有的 `Menu` 都放在外层 `HStack` 上，于是箭头被夹在中间。官方插件行此前没有 `Menu`，箭头才恰好贴着最右。

目标：箭头固定在最右侧，仍是「整行内容区可点击进详情」的语义。

## Approach

只调整 `PluginRow` 的层级：把 `Image(systemName: "chevron.right")` 从详情 `Button` 的 label 移到最外层 `HStack` 的末尾（`Toggle` 与 `Menu` 之后），布局变为 `[图标+文案+spacer] [开关] [菜单] [箭头]`。

- `Button` 的 label 内保留 `Spacer()`，内容区仍然撑满可用宽度，整段都能点进详情；箭头本身不再属于按钮热区（纯装饰，不承担点击）。
- 箭头对辅助功能隐藏，避免它被当成可点击元素读出；详情入口的可读性由按钮已有的 `accessibilityLabel` 承担。
- 不新增任何状态或组件，`Toggle`/`Menu`/回调签名都不动。

## Files to modify

- `Sources/Leap/PluginSettingsPage.swift`（`PluginRow`，约 286–330 行）

## Reuse

- 现有 `Button(action: requestDetails)` + `Spacer()` + `.contentShape(Rectangle())` 的整行点击写法（`PluginSettingsPage.swift:287-317`），只挪动箭头位置。
- 现有无障碍写法（按钮 `accessibilityLabel` / 控件 `accessibilityIdentifier`），不新增标识。

## Steps

- [x] `PluginRow` 详情按钮 label 内删掉 `Image(systemName: "chevron.right")`
- [x] 在最外层 `HStack` 末尾（`Menu` 之后）加回该箭头，保留 `.foregroundStyle(.secondary)`，并加 `.accessibilityHidden(true)`
- [x] 编译并目视确认：官方插件行 `[图标+文案] … [开关] [›]`，本地插件行 `[图标+文案] … [开关] [⋯] [›]`

## Verification

- `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- `swiftlint`
- 手动：内置/自定义两类插件行箭头都在最右；点文案区仍能进入详情；点开关只切换启用状态不跳页；点 `⋯` 只弹菜单
- 现有 UI 测试 `LeapUITests` 中 `settings.pluginEnabled.<id>` 的使用不依赖箭头层级，无需改动
