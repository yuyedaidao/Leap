# 插件启用/禁用状态

## Context

Leap 的插件系统目前没有启用/禁用概念：`InstalledPluginCatalog` 扫描到的所有插件（官方 + 本地）都会进入启动器并可执行。需要支持禁用某个插件，禁用后该插件在启动器中完全隐藏、无法使用。

**已确认的决策：**
- 官方（内置）插件与本地插件**都允许禁用**
- 禁用后启动器**完全隐藏**（不置灰展示）
- 开关入口：**设置页插件行 + 插件详情页**

## 现状（代码事实）

- 启动器命令源：`LauncherModel.reloadPlugins`（`Sources/Leap/LauncherModel.swift:175`）→ `InstalledPluginCatalog.load()`（`Sources/LeapCore/InstalledPluginCatalog.swift:133`）→ `[PluginCommandDescriptor]`
- 设置页列表源：`PluginInstallationModel.reloadPlugins`（`Sources/Leap/PluginInstallationModel.swift:208`）→ `catalog.loadPlugins()`（`InstalledPluginCatalog.swift:63`）→ `[InstalledPluginDescriptor]`
- 最近使用记录（`LauncherModel.swift:396`）只保留与当前 `commands` 匹配的键 —— 在 `load()` 过滤后，禁用插件的最近记录自动不再出现，无需额外处理
- 刷新链路已存在：`PluginInstallationModel` 的 `didInstall` 回调（`SettingsCoordinator.swift:82` 注入 `{ launcher?.reloadPlugins() }`），安装/卸载后已在用
- 持久化惯例：UserDefaults + 可注入 `defaults` 的小型 Store（参考 `RecentCommandStore`，`Sources/LeapCore/RecentCommandStore.swift:14`）
- 设置页行：`PluginSettingsPage.swift:261` `PluginRow`（整行是详情 Button，本地插件右侧有管理 Menu）
- 详情页头部：`PluginDetailsView.swift:30` `PluginDetailsHeader`（右侧是 `PluginManagementActions`）

## Approach

1. **新增 `PluginEnabledStore`**（LeapCore）：UserDefaults 持久化"已禁用插件 id 集合"，提供 `isEnabled(id:)` / `setEnabled(_:id:)`；`defaults` 与 `key` 可注入，默认启用（集合为空 = 全部启用）。
2. **启动器过滤**：`InstalledPluginCatalog` 增加 `enabledStore` 构造参数（默认新建实例），`load()` 返回前过滤掉禁用插件的命令。`loadPlugins()` **不过滤**（设置页要能看到禁用项以便恢复）。
3. **设置页开关**：`PluginRow` 在管理 Menu 旁加 `Toggle`；`PluginDetailsHeader` 同样加 `Toggle`。两处都绑定到 `PluginInstallationModel` 暴露的状态。
4. **状态协调**：`PluginInstallationModel` 持有 store，新增 `isEnabled(_:)` / `setEnabled(_:enabled:)`；切换后写 store、刷新自身可观察状态，并复用现有 `didInstall` 回调触发启动器 `reloadPlugins()`。

## Files to modify

- 新增 `Sources/LeapCore/PluginEnabledStore.swift`
- `Sources/LeapCore/InstalledPluginCatalog.swift`（构造参数 + `load()` 过滤）
- `Sources/Leap/PluginInstallationModel.swift`（持有 store、`isEnabled`/`setEnabled`、切换后触发 `didInstall`）
- `Sources/Leap/PluginSettingsPage.swift`（`PluginRow` 加 Toggle，向详情页传递绑定）
- `Sources/Leap/PluginDetailsView.swift`（`PluginDetailsHeader` 加 Toggle）
- 新增 `Tests/LeapTests/PluginEnabledStoreTests.swift`；在现有 catalog 测试中补禁用过滤用例

## Steps

- [x] 新增 `PluginEnabledStore`：UserDefaults 存 `disabledPluginIDs`（字符串数组），`isEnabled` / `setEnabled`，注入式 `defaults`/`key`
- [x] `InstalledPluginCatalog.init` 增加 `enabledStore: PluginEnabledStore = .init()`，`load()` 过滤禁用插件
- [x] `PluginInstallationModel` 持有 store，暴露 `isEnabled(_:)` 与 `setEnabled(_:enabled:)`（写 store + 刷新可观察状态 + 调 `didInstall`）
- [x] `PluginRow` 加 `Toggle`，绑定到 model；禁用行在副标题体现"已禁用"
- [x] `PluginDetailsHeader` 加 `Toggle`，状态由设置页传入
- [ ] 测试：store 持久化/默认值；`load()` 禁用过滤（官方 + 本地各一）；model 切换后状态与回调
- [x] UI 测试或手动验证：禁用后启动器搜索不到、最近记录消失；重新启用恢复

## Verification

- `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`
- `swiftlint`
- 手动：设置页禁用某官方插件 → 启动器搜索其命令无结果 → 详情页重新启用 → 恢复
