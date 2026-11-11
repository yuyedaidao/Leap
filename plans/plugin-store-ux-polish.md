# 插件商店体验修补（图标 / 详情 / 更新时间 / 更新弹窗）

## Context

插件商店刚上线（`f4b7a33` + `d59c6ca`），实用中暴露五个问题：

1. 商店列表里没有图标 —— `PluginStorePage` 的行把 `PluginIcon(iconURL: nil, …)` 写死，索引 `PluginStoreEntry` 也没有图标字段。
2. 商店条目没有详情 —— 行不可点击，只能看到一行文字和一个动作按钮。
3. 「索引更新于 …」挂在 `List` 的 `Section` footer 上，随滚动跑掉，容易被当成普通行。
4. 商店安装/更新的进度画在列表上方（`downloadBanner`），和「从远程地址安装」的弹窗两套体验。
5. 点了「更新到 x.x.x」之后进度条消失但条目仍显示「更新到 x.x.x」：商店流程的下载进度在列表里、真正的确认步骤是 `PluginSettingsPage` 挂的 `confirmationDialog`，横幅消失后用户看不到「还要确认一次」，把未确认当成已完成。本机实证：`~/Library/Application Support/Leap/Plugins/com.padding.leap.json-formatter` 仍是 1.0.0，而商店索引是 1.1.0。模型层刷新是对的（`finishInstallation()` → `reloadPlugins()`，`PluginInstallationModelTests.installAndRefresh` 已覆盖），所以问题在交互路径，不在状态同步。

顺带：商店索引缺 `store.json` 的 404 已在上一轮修好（数据推到 LeapPlugins `main`，错误文案改为 `PluginStoreError.notFound`），本计划不再涉及。

目标：商店列表像插件列表一样有图标、可点进详情；更新时间常驻底部；安装/更新复用「从远程地址安装」那个弹窗（进度 + 确认 + 错误 + 取消都在一个地方），从而让第 5 条不再可能发生。

## Approach

### 1. 图标：索引增加 `icon`，App 侧远程加载

- `PluginStoreEntry` 增 `public let icon: String?`（解码用 `decodeIfPresent`，老索引/老 App 互相兼容）。
- 校验放在 `isValidEntry` 里：给了 icon 就必须是安全相对路径（非空、非绝对、无 `..`）、扩展名限 `png/jpg/jpeg/icns`；不合格时**只丢弃 icon 字段，不丢整条**（图标是装饰信息，不值得让条目消失）。
- `PluginStoreEntry.iconURL(source:)` 拼 `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>/<icon>`，与现有 `installAddress(source:)` 同一套 owner/repo/ref 参数化。
- LeapPlugins 仓 `Scripts/build-index.mjs` 输出 `icon: manifest.icon`（缺省不写），`tests/index.test.cjs` 断言索引 icon 与清单一致，重新生成 `store.json` 并推送。
- 商店行图标：已安装插件用本机受管副本的 `iconURL`（`PluginIcon(plugin:)`，零网络），未安装用 `AsyncImage` 加载索引地址；两者失败都回退现有的符号占位（`PluginIcon(iconURL: nil, runtime:)`）。不要为图标新增下载器/缓存层 —— `AsyncImage` 走 `URLSession.shared` 缓存，App 未开沙盒、`raw.githubusercontent.com` 已经能直连。

### 2. 详情：已安装复用现有详情页，未安装用商店详情页

- `PluginSettingsRoute` 增 `case storeDetails(String)`（存 entry id）。商店详情页是商店的子页，返回回商店，而不是插件列表。
- 行交互照 `PluginRow` 的做法：图标 + 文字区域包一个 `.buttonStyle(.plain)` 的 Button（整块 `contentShape`），右侧保留独立的安装/更新按钮（现有 identifier `settings.pluginStoreInstall.<id>` / `settings.pluginStoreUpdate.<id>` 不变，UI 测试依赖它），最右加 `chevron.right`。
- 点击行为按状态分流（用户建议「复用现有插件详情页」）：
  - 已安装 / 可更新 → `route = .details(id)`，直接进现有 `PluginDetailsView`（启用开关、命令详情、更新/卸载全都在）。
  - 未安装 → `route = .storeDetails(entry.id)`，进新页面 `PluginStoreDetailsView`：图标、名称、版本、简介、命令标题列表、运行时、最低宿主版本、来源仓库 `owner/repo/path`；底部一个「安装」按钮（不兼容宿主时显示现有「需要 Leap x.y.z」文案）。只展示索引已有字段，不为看详情去下载插件。
  - 不显示本机安装路径（见下一条），也不在商店详情页里编造命令关键字/内容规则（索引里没有这些数据）。
- `LeapSettingsView`：返回按钮按目标分流 —— `.storeDetails` 回 `.store`，其余回 `.list`；`detailTitle` 对 `.storeDetails` 显示商店条目名称。
- 现有详情页的技术信息删除「安装目录」字段（用户要求：本地/远程插件的安装路径都不该暴露）；`PluginDetailsUITests` 里对应的 `settings.pluginDetails.directory` 断言同步删掉。

### 3. 「索引更新于」：固定底部状态条

- 删掉 `Section` footer，改用 `.safeAreaInset(edge: .bottom, spacing: 0)`：`Divider()` + 一行 caption（次要色），左侧「索引更新于 <日期时间>」，右侧在有缓存且刷新失败时显示「显示上次结果」（复用现有 `store.isShowingCachedResult`）。
- 状态条常驻、不随列表滚动，也不占工具栏；identifier `settings.pluginStoreUpdatedAt` 供 UI 测试断言。

### 4. 安装/更新改成弹窗（顺带解决第 5 条）

- `PluginInstallationModel` 新增 `private(set) var storeInstallName: String?`；`installFromStore(address:pluginID:)` 增加 `pluginName` 参数，设好 `storeInstallName` 后置 `isRemotePresented = true`（复用 `PluginSettingsPage` 已挂的 `.sheet`），在 `rejectInstallation()` / `finishInstallation()` / `clearCandidate()` 里清空。
- `RemotePluginInstallView` 在 `storeInstallName != nil` 时：标题改成「安装 <名称>」/「更新 <名称>」，隐藏说明文字、地址输入框与「下载并检查」按钮；其余（阶段文案、进度、候选信息、错误、取消、确认按钮）完全复用。候选确认已经有名称/版本/运行时/命令/来源/提交/信任警告，确认步骤从此不可能被忽略。
- `PluginStorePage` 删掉 `downloadBanner`；`isBusy`（禁用行内按钮）保留。

## Files to modify

Leap 仓：

- `Sources/LeapCore/PluginStoreIndex.swift`：`icon` 字段 + 校验 + `iconURL(source:)`。
- `Sources/Leap/PluginStorePage.swift`：行可点击 + 图标 + 删 `downloadBanner` + 底部状态条。
- `Sources/Leap/PluginStoreDetailsView.swift`（新增）：商店条目详情页。
- `Sources/Leap/PluginSettingsPage.swift`：`PluginSettingsRoute.storeDetails` 分支。
- `Sources/Leap/LeapSettingsView.swift`：返回目标分流 + `detailTitle`。
- `Sources/Leap/PluginInstallationModel.swift`：`storeInstallName` + `installFromStore(pluginName:)` + 打开 sheet。
- `Sources/Leap/RemotePluginInstallView.swift`：商店模式（隐藏地址输入）。
- `Sources/Leap/PluginDetailsView.swift`：`PluginDetailField` 从 `private` 改 internal 供复用；删除「安装目录」字段。
- `Tests/LeapTests/PluginStoreIndexTests.swift`：icon 解码/非法 icon 丢弃/`iconURL` 拼接。
- `Tests/LeapTests/PluginInstallationModelTests.swift`：`installFromStore` 打开 sheet，安装完成后该 ID 版本刷新为候选版本、`storeInstallName` 清空。
- `Tests/LeapUITests/PluginStoreUITests.swift`：点击未安装条目进商店详情并返回商店、条目点击进已安装详情、底部状态条存在。
- `Tests/LeapUITests/PluginDetailsUITests.swift`：删掉「安装目录」断言。

LeapPlugins 仓（`/Users/wyq/Work/Project/2026/LeapPlugins`，直接提交 `main`）：

- `Scripts/build-index.mjs`：输出 `icon`。
- `tests/index.test.cjs`：断言 icon 与清单一致。
- `store.json`：重新生成。

## Reuse

- `PluginIcon`（`Sources/Leap/PluginListView.swift`）：本地图标与符号占位，商店行直接复用。
- `PluginRow` 的整行 Button + `contentShape` + `chevron.right` 模式：商店行照抄，保持两处列表交互一致。
- `PluginDetailField` / `.listStyle(.inset)`（`Sources/Leap/PluginDetailsView.swift`）：商店详情页沿用它，避免自造字段样式。
- `RemotePluginInstallView` + `PluginSettingsPage` 的 `.sheet`：进度/候选确认/错误/取消全在这里，不再新写进度 UI。
- `PluginInstallationModel.downloadRemote/confirmInstallation/finishInstallation`、`RemotePluginInstallationTests.Fixture` + `GitHubFixtureClient`：测试沿用现有夹具。
- `PluginStoreSource` 的 owner/repo/ref 参数化：`iconURL(source:)` 与 `installAddress(source:)` 同源。
- SwiftUI `AsyncImage`：远程图标，不新增下载器。

## Steps

- [x] 1. LeapPlugins：`build-index.mjs` 输出 `icon`，补 `tests/index.test.cjs` 断言，`node Scripts/build-index.mjs` 重新生成 `store.json`，`node --test tests/` 通过后推送 `main`。
- [x] 2. `PluginStoreEntry` 增 `icon`、`iconURL(source:)`，`isValidEntry` 校验图标路径（不合格只丢 icon），补 `PluginStoreIndexTests`。
- [x] 3. `PluginStorePage` 行改造：可点击（`.plain` Button + chevron）、图标（本地优先 / AsyncImage 兜底）、保留原动作按钮与 identifier。
- [x] 4. `PluginStoreDetailsView` + `PluginSettingsRoute.storeDetails` + `LeapSettingsView` 返回分流与标题；`PluginDetailField` 改 internal 并删除「安装目录」字段。
- [x] 5. 底部状态条替换 `Section` footer（含「显示上次结果」提示）。
- [x] 6. `installFromStore(pluginName:)` + `storeInstallName` + `RemotePluginInstallView` 商店模式；删除 `downloadBanner`。
- [x] 7. 测试：`PluginInstallationModelTests` 增商店安装用例，`PluginStoreUITests` 增导航/状态条用例，`PluginDetailsUITests` 删安装目录断言。
- [x] 8. `xcodebuild test`（含 LeapTests + LeapUITests）、`swiftlint`，手动跑一遍真机流程。

## Verification

- Leap：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`（再跑 `-only-testing:LeapUITests/PluginStoreUITests -only-testing:LeapUITests/PluginDetailsUITests`）。
- LeapPlugins：`node Scripts/build-index.mjs && node --test tests/`，并 `curl` 校验 `https://raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json` 里带 `icon`。
- `swiftlint` 无新增告警。
- 手动（真机）：商店页三个条目都有图标；点未安装条目进商店详情并返回商店；点已安装条目进现有详情页；「索引更新于」固定在底部；点「更新到 1.1.0」弹出安装弹窗（标题「更新 JSON 格式化」、无地址输入），确认后弹窗关闭、行变「已安装」、插件列表里版本变成 1.1.0。

## Risks

- `store.json` 加字段需要再推一次 LeapPlugins；旧客户端忽略未知字段（`Codable` 忽略多余键），不会坏。
- 远程图标依赖 `raw.githubusercontent.com` 直连（App 未开沙盒）；离线/被墙时只是回落到符号占位，不影响列表。
- 商店详情页复用的是索引字段，视觉上比已安装插件的详情页简（没有关键字/内容规则）；这是数据边界，不是遗漏。
- 删除「安装目录」会改变现有技术信息区块，`PluginDetailsUITests` 必须同步修改，否则会红。
- 第 5 条的根因是「确认步骤不可见」，我按本机实证推断，未实机复现点击路径；改造后弹窗即流程，需在手动验证里确认一次真实更新（含确认弹窗）确实把 1.0.0 换成 1.1.0。
