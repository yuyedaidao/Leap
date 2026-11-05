# 关于页「检查更新」按钮省略号问题

## Context

用户反馈：关于页的「检查更新…」按钮一直带省略号，怀疑页面在该状态下持续检查更新。

调查结论：**不是持续检查，省略号是按钮标题里的硬编码字符**，不是进度指示。

- `Sources/Leap/DataSettingsPage.swift:98` — `Button("检查更新…", action: updates.checkForUpdates)`，省略号写死在标题里。
- 检查进行中时，`AppUpdateController.canCheckForUpdates` 变为 `false`（`Sources/Leap/AppUpdateController.swift:31`、`Sources/Leap/AppUpdateController.swift:74-78`，由 KVO 观察 `SPUUpdater.canCheckForUpdates` 更新），按钮因此变灰；检查结束后恢复。所以状态反馈本来就靠禁用态 + Sparkle 自带的「正在检查更新…」窗口，标题不需要常驻省略号。

问题在于静态省略号在中文界面里会被读成"进行中"，产生误导。README（`README.md:13`）与 UI 测试只用无障碍标识 `settings.checkForUpdatesButton` 定位按钮，不依赖标题文本。

## Approach

只改按钮标题，去掉省略号：`检查更新…` → `检查更新`。不引入新的"检查中"状态字段（Sparkle 已通过禁用态和自带进度窗口给出反馈，新增状态属多余抽象）。

## Files to modify

- `Sources/Leap/DataSettingsPage.swift:98` — 按钮标题去掉省略号。

（`Tests/LeapUITests/SettingsWindowUITests.swift:18` 用 accessibility identifier 定位，无需改动。）

## Reuse

- 现有状态来源：`AppUpdateController.canCheckForUpdates`（`Sources/Leap/AppUpdateController.swift:31`），按钮的 `.disabled(!updates.canCheckForUpdates)`（`Sources/Leap/DataSettingsPage.swift:99`）已提供进行中反馈。

## Steps

- [x] 修改 `Sources/Leap/DataSettingsPage.swift:98` 标题为 `"检查更新"`。

## Verification

- [x] `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- [x] `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapUITests/SettingsWindowUITests`（若环境允许跑 UI 测试）
- [x] 手动确认：打开 设置 → 关于，按钮显示「检查更新」；点击后按钮变灰、Sparkle 弹窗出现「正在检查更新…」，结束后恢复可点。
- [x] `swiftlint`
