# 程序坞图标唤起启动器 + 可选的程序坞显示开关

## Context

Leap 现在是「常驻 Dock 的普通应用」，但点 Dock 图标只会把应用激活，什么都不发生：`AppDelegate` 没有实现 `applicationShouldHandleReopen`，启动器面板只在全局快捷键 / 插件触发时出现。同时用户想要一个设置项，能决定图标是否出现在程序坞里（纯启动器形态）。

目标：

1. 点程序坞图标（或 Finder/Launchpad 再次打开已在运行的应用）= 弹出启动器面板。
2. 设置 → 通用 → 启动器 增加开关「在程序坞中显示图标」，关闭后应用变成 `.accessory`（无 Dock 图标、不进 ⌘Tab），重启后保持。

**已确认的决策：**

- 新开关默认 **显示**（`UserDefaults` 无记录 = `true`），老用户升级后 Dock 图标照旧，只有主动关闭才进入纯启动器形态。
- 设置窗口已打开时点 Dock 图标也 **一律弹出启动器**（不做「是否已有可见窗口」分支）。
- 本次 **不写 `## UI 验收` 块**：本机是 macOS 应用，sim-use lane 无法验收；用构建 + 单测 + 手动验收清单，效果由用户亲眼确认后再提交。

## 现状（代码事实）

- 应用没有 `LSUIElement`：`plutil -p /Applications/Leap.app/Contents/Info.plist` 与 `Project.swift` 的 `infoPlist` 都没有该键，代码里也没有任何 `setActivationPolicy` 调用 → 当前是默认的 `.regular`，Dock 图标始终存在。
- `Sources/Leap/AppDelegate.swift:6` 是唯一 `NSApplicationDelegate`，由 `LeapApp.swift:6` 的 `@NSApplicationDelegateAdaptor` 接入；只实现 `applicationDidFinishLaunching` / `applicationShouldTerminateAfterLastWindowClosed` / `applicationWillTerminate` / `applyAppearancePreference`。
- 启动器展示入口：`LauncherPanelController.present(on:fallbackLocation:)`（`Sources/Leap/LauncherPanelController.swift:73`），`AppDelegate.makeGlobalHotKey()` 与启动时的 `Task` 已经调用它；`hideForUpdate()` 收起。
- 设置页结构：`Sources/Leap/LeapSettingsView.swift` → `GeneralSettingsPage.swift`，其中 `LaunchBehaviorSection` 已有「登录时启动 Leap」`Toggle` + `settings.launchAtLoginToggle` 标识，紧随其后是「外观」Picker。
- 状态协调惯例：`SettingsCoordinator`（`Sources/Leap/SettingsCoordinator.swift`）是 `@MainActor @Observable`，持有登录项状态并提供 `setLaunchAtLogin` 之类的方法；`AppDelegate` 在初始化时注入带副作用的闭包（见 `applyShortcut`）。
- 持久化惯例：`UserDefaults` + 可注入 `defaults`/`key` 的小型 Store（`Sources/LeapCore/PluginEnabledStore.swift`、`RecentCommandStore.swift`），单测用独立 suite 验证。
- 现有 `UserDefaults` 键：`appearancePreference`、`globalHotKeyShortcut`、`disabledPluginIDs`、`launcherUsageRecords`。

## Approach

1. **新增 `Sources/LeapCore/DockVisibility.swift`**（小 Store，惯例同 `PluginEnabledStore`）：
   - `defaultsKey = "showsDockIcon"`，`init(defaults:key:)` 可注入。
   - `isEnabled`：未写过 → `true`（保持现状，升级用户不受影响）。
   - `setEnabled(_:)` 写入。
   - `static func activationPolicy(isEnabled: Bool) -> NSApplication.ActivationPolicy`（`true → .regular`，`false → .accessory`），把「开关语义 → AppKit 策略」的映射集中一处，AppDelegate 与设置页共用。
2. **`AppDelegate` 应用策略**：
   - 新增 `applicationWillFinishLaunching(_:)`，在其中 `NSApp.setActivationPolicy(...)`（早于窗口创建，避免 Dock 图标闪一下再消失）。
   - 新增 `applicationShouldHandleReopen(_:hasVisibleWindows:)`：`launcherPanelController?.present()` 并 `return false`（阻止系统默认的窗口重开逻辑）。
3. **`SettingsCoordinator`**：
   - 持有 `private let dockVisibility: DockVisibility` 与 `private(set) var showsDockIcon: Bool`（init 时读取）。
   - `func setShowsDockIcon(_ enabled: Bool)`：先 `NSApp.setActivationPolicy(...)`，成功（返回 `true`）才写 store 并更新 `showsDockIcon`；失败保留旧值并记 `showsDockIconError`（复用 `SettingsErrorMessage`）。
4. **设置页**：`LaunchBehaviorSection` 在「登录时启动 Leap」后加 `Toggle("在程序坞中显示图标", ...)` + 一行 caption 说明（关闭后从 ⌘Tab 中一并消失，仍可用全局快捷键唤起），`accessibilityIdentifier("settings.showDockIconToggle")`。
5. **单测**：`Tests/LeapTests/DockVisibilityTests.swift`（默认值、往返读写、策略映射）。
6. 不做的事（明确排除）：不引入 `LSUIElement` 静态键（运行时可切换必须靠 `setActivationPolicy`）、不新增菜单栏图标（`NSStatusItem`/`MenuBarExtra`）、不把开关做成「隐藏后仍留在 ⌘Tab」的混合形态。

## Files to modify

- 新增 `Sources/LeapCore/DockVisibility.swift`
- `Sources/Leap/AppDelegate.swift`（`applicationWillFinishLaunching` + `applicationShouldHandleReopen`）
- `Sources/Leap/SettingsCoordinator.swift`（`showsDockIcon` 状态 + `setShowsDockIcon`）
- `Sources/Leap/GeneralSettingsPage.swift`（新 Toggle）
- 新增 `Tests/LeapTests/DockVisibilityTests.swift`

## Steps

- [x] 新增 `DockVisibility`（读/写 + 策略映射）
- [x] `AppDelegate.applicationWillFinishLaunching` 应用启动时的策略
- [x] `AppDelegate.applicationShouldHandleReopen` 弹出启动器并返回 `false`
- [x] `SettingsCoordinator` 暴露 `showsDockIcon` / `setShowsDockIcon`（失败不落盘）
- [x] `LaunchBehaviorSection` 加开关与说明文案
- [x] 单测 `DockVisibilityTests`
- [x] 构建 + 单测 + `swiftlint` + 手动验收

## Verification

- `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`
- `swiftlint`
- 手动（用户亲眼确认，确认前不提交）：
  1. 运行应用 → 点 Dock 图标，启动器面板出现且能直接输入搜索词。
  2. 设置 → 通用 → 启动器：关闭「在程序坞中显示图标」→ Dock 图标与 ⌘Tab 条目消失，全局快捷键仍能唤起，面板内 ⌘, 仍能打开设置；重新打开开关 → 图标回来。
  3. 退出并重启应用 → 开关状态与 Dock 图标表现保持。

## 风险

- `.accessory` 会同时移除菜单栏与 ⌘Tab 条目，属于用户预期内的取舍；需在设置页 caption 里写清。
- 若 `setActivationPolicy` 返回 `false`（极少见，通常是未打包的运行方式），开关不落盘，避免出现「设置显示关闭但图标还在」。
- Dock 图标点击与新开关只影响主应用激活策略，不影响启动器面板的 `nonactivatingPanel` 行为；但需实测面板在应用激活状态下仍能接收键盘输入。
- UI 测试 `SettingsWindowUITests` 依赖 `settings.launchAtLoginToggle` 存在，新增 Toggle 不改变该标识；需跑一遍 LeapUITests 确认设置页布局断言未受影响。
