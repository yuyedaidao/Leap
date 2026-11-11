# 插件商店（官方索引 + 插件页二级页）

## Context

用户必须自己拿到某个插件的目录链接才能安装，Leap 不知道官方仓库里有哪些插件可装。本变更让插件页能进入「插件商店」，浏览、搜索官方插件，并直接安装或更新。

现有远程安装链路（`add-remote-plugin-installation`，12/15）已经完整，商店只补「发现」这一层：

```
raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json   (1 次请求，不占 API 限额)
        |
        v  PluginStoreIndex(plugins: [Entry])
PluginStorePage 列表 + 搜索
        |
        v  点「安装 / 更新」：tree/main/<entry.path>
现有远程安装流水线：解析并固定提交 → 逐文件下载 → 确认弹窗 → 受管安装
        |
        v  InstalledPluginCatalog 刷新 → 启动器索引刷新
```

## 已确认决策

1. **索引文件方案**：仓库根 `store.json`，App 读它渲染列表；不扫描目录。
2. **索引是生成物**：仓库内脚本从 `plugins/*/manifest.json`（描述取 README 首句）生成，并加节点测试断言索引与清单一致，防漂移。
3. **v1 只有官方来源**：写死 `yuyedaidao/LeapPlugins` + `main`；读取层接收 owner/repo/ref，后续加 tap 只需加来源列表。
4. **页面形态**：方案 B —— 插件页内的二级页（占用右侧详情列，返回箭头回插件列表）；商店是新文件里的独立页面，不塞进 `PluginSettingsPage`。
5. **入口位置**：插件列表页工具栏，搜索框右侧、与「安装插件」同处 trailing 操作区（`storefront` 图标按钮）。
6. **更新入口 v1 就做**：索引里存在的已安装插件，插件页「更新」直接走商店更新——跳到商店页并开始下载，不再弹「本地 / 远程」选择；本地目录装的插件保持原流程。
7. **索引不固定提交**：索引只带 `path`，安装时由现有下载器解析并固定真实提交，确认弹窗显示真实提交与清单版本。

## 索引格式（LeapPlugins 仓 `store.json`）

```json
{
  "schemaVersion": 1,
  "name": "Leap 官方插件",
  "plugins": [
    {
      "id": "com.padding.leap.json-formatter",
      "name": "JSON 格式化",
      "version": "1.0.0",
      "summary": "在 Leap 里粘贴 JSON，自动缩进对齐",
      "path": "plugins/json-formatter",
      "runtime": "javascript",
      "minimumHostVersion": "0.0.2",
      "commands": ["JSON 格式化"]
    }
  ]
}
```

读取时校验：`schemaVersion == 1`、条目数上限（500）、id 非空且不重复、id 不得是内置插件 ID、`path` 为安全相对路径；全部用既有的路径安全规则。不合格条目跳过并记日志，整份索引不可用时保留缓存。

## 交互与状态

```
插件页（.list）
  toolbar: [来源分段]      ...      [插件商店] [安装插件]
                                     |
                                     v
插件页（.store）  标题「插件商店」，返回箭头回 .list
  [搜索]  刷新
  官方插件 · 3
   icon | 名称 / 简介             |  [安装] / [更新到 1.1.x] / [已安装]
        | 版本 · 命令数 · 运行时   |
  下载中：顶部横幅 ProgressView + 「n / m 个文件」 + 取消
  错误：SettingsErrorMessage（离线时优先显示缓存并标注「显示上次结果」）

插件页（.details）  现有详情页；商店插件的「更新」→ 跳到 .store 并开始下载
```

状态判定（纯函数，放 `LeapCore`，便于单测）：按 `id` 匹配已安装插件，
`未安装` / `已安装`（版本相等或更高）/ `可更新`（`.compare(options: .numeric) == .orderedAscending`）。同版本内容变化不视为更新（v1 限制）。

## Files to modify

新增（Leap 仓）：

- `Sources/LeapCore/PluginStoreIndex.swift`：索引模型、解码与校验、`status(for:installedVersions:)`、`installAddress(...)`。
- `Sources/LeapCore/PluginStoreCatalog.swift`：`refresh()` 经 `RemotePluginHTTPClient` 拉取 raw `store.json`、解码校验、写缓存；`cached()` 读缓存。
- `Sources/Leap/PluginStoreModel.swift`：`@MainActor @Observable`，组合 catalog 与安装模型，暴露 `entries / isLoading / errorMessage / lastUpdated / refresh()`。
- `Sources/Leap/PluginStorePage.swift`：商店列表、搜索、行内动作、下载横幅、空/错误态。
- `Tests/LeapTests/PluginStoreTests.swift`（索引校验、状态判定、缓存与失败回退）
- `Tests/LeapUITests/PluginStoreUITests.swift`（导航、搜索、按钮状态、离线缓存渲染）

修改（Leap 仓）：

- `Sources/LeapCore/AppPaths.swift`：新增商店缓存文件路径（`Application Support/Leap/PluginStore/index.json`）。
- `Sources/Leap/PluginSettingsPage.swift`：顶层 `PluginSettingsRoute` 枚举替代 `selectedPluginID`；工具栏商店按钮；详情页「更新」分流到商店；确认弹窗补来源与提交行。
- `Sources/Leap/LeapSettingsView.swift`：改用 `route` 状态，`插件商店` 标题与返回按钮，插件列表变化时回收失效详情。
- `Sources/Leap/SettingsCoordinator.swift`：持有 `pluginStore: PluginStoreModel`，与 `pluginInstallation` 同级。

外部仓库（`yuyedaidao/LeapPlugins`，需在其工作副本内提交）：

- `Scripts/build-index.mjs`（从清单 + README 首句生成 `store.json`）、`store.json`、`tests/index.test.cjs`、README 补充「上架 = 加目录 + 重跑生成」。
- 新增插件：真实数据由仓库现有 3 个插件提供，本变更不虚构插件。

## Git 工作流

- 本功能在独立分支开发：从 `main` 新建 `feature/plugin-store`（当前 `main` 干净，仅本计划文件未跟踪）。
- 完成后按主题拆分提交（如：LeapCore 索引与缓存 / 商店页面与导航 / 更新入口与确认信息 / 测试 / 文档 / 本计划文件），推送到 `origin/feature/plugin-store`；不直接推进 `main`，是否合并留给用户。
- LeapPlugins 仓同样新建分支（`feature/store-index`）提交生成脚本、`store.json`、测试与 README，推送后由用户决定合并。
- 每个仓库推送前确认：无临时文件、无缓存/构建产物、`plans/plugin-store.md` 一并提交。

## Reuse

- `RemotePluginHTTPClient` / `GitHubPluginHTTPClient`：已允许 `raw.githubusercontent.com` 与 `api.github.com`，带主机白名单与重定向守卫；索引就是一次 `download`。
- `RemotePluginDownloader`：`tree/<ref>/<path>` 地址解析、提交固定、限流/体积/取消/错误中文映射。
- `PluginInstaller`、`PluginTrustRecord`（含 `source`）、`RemotePluginSource`：安装、替换回滚、来源记录。
- `PluginInstallationModel`：`downloadRemote` / `progress` / `remotePhase` / `isConfirmationPresented` / `replacementMessage` 直接复用，新增 `updating:` 参数即可支持定向更新。
- `PluginManifestValidator.isSafeRelativePath` 思路、`PluginLibraryQuery` 的搜索匹配方式、`PluginIcon` 的占位图标、`SettingsErrorMessage`、`ContentUnavailableView` 空态。
- 测试：`GitHubFixtureClient`（按绝对 URL 回复）用于索引与缓存测试。

## Steps

- [x] 0. 从 `main` 新建分支 `feature/plugin-store`，后续提交都在该分支上。
- [x] 1. `PluginStoreIndex`：模型、解码、条目校验（数量/ID/内置 ID/路径）、`status` 与 `installAddress`；单测覆盖合法索引、缺字段、重复 ID、越界路径、内置 ID、版本比较。
- [x] 2. `PluginStoreCatalog`：`refresh()` 下载 + 校验 + 原子写缓存，`cached()` 读回；用 `GitHubFixtureClient` 测成功、HTTP 错误、限流、坏 JSON、缓存保留。
- [x] 3. `AppPaths` 增加缓存路径；`PluginStoreModel` 先展示缓存再刷新，网络失败保留缓存并给离线提示。
- [x] 4. `PluginSettingsRoute` + `PluginSettingsPage` / `LeapSettingsView` 导航改造（列表 / 详情 / 商店），工具栏加商店按钮，保持现有 accessibility identifier 不变。
- [x] 5. `PluginStorePage`：搜索、分组列表、行内「安装 / 更新 / 已安装」、下载横幅（进度 + 取消）、错误与空态。
- [x] 6. `PluginInstallationModel.downloadRemote(address:updating:)` 支持定向更新；`PluginSettingsPage` 详情「更新」分流：索引内插件 → 商店更新，其余保持原对话框。
- [x] 7. 确认弹窗在远程候选时显示来源仓库、目录与提交短 SHA（补齐远程确认信息）。
- [x] 8. `SettingsCoordinator` 注入 store model；`AppDelegate` 侧无需改动（除测试离线开关）。
- [x] 9. UI 测试：插件页 → 商店 → 搜索过滤 → 行状态；用 `-leap-testing-offline-store` 跳过刷新、预先写入缓存夹具，保证不依赖网络。
- [x] 10. LeapPlugins 仓：`Scripts/build-index.mjs` + 生成 `store.json` + `tests/index.test.cjs` + README 更新。
- [x] 11. 文档：`Docs/PluginDevelopment.md` 增加官方商店索引与目录约定说明。
- [x] 12. 构建、`LeapTests`、商店 UI 测试、`swiftlint`。（不改工程配置则无需 `tuist generate`；若把 store model 加进 LeapTests 源，则需重新生成。）
- [ ] 13. 按主题拆分提交，推送 `origin/feature/plugin-store`；LeapPlugins 仓在 `feature/store-index` 分支提交并推送。

## Verification

- `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- `xcodebuild test ... -only-testing:LeapTests`（新增索引/缓存/状态单测）
- UI：`-only-testing:LeapUITests/PluginStoreUITests`
- 手工（真实网络）：打开商店看到 3 个官方插件 → 安装 json-formatter → 详情页看到「插件商店」来源 → 改版本后点「更新」→ 确认弹窗显示来源与提交 → 更新成功且启动器命令可用；断网重启后商店仍显示缓存并标注离线。
- LeapPlugins：`node Scripts/build-index.mjs` 后 `git diff --exit-code store.json`、`node --test tests/*.test.cjs`
- `swiftlint`（只关注本次改动的文件）

## Non-goals（v1 明确不做）

- 第三方来源 / tap 增删与多来源 UI（读取层已为它留口）。
- 商店内插件详情页、README 全文、截图、评分、下载量。
- 图标网络加载（列表用运行时占位图标，复用现有 SF Symbol 规则）。
- 后台自动检查更新、静默更新、自动安装依赖。
- 同版本内容变化的「重新安装」入口、私有仓库认证、非 GitHub 托管。

## 风险与注意

- 索引与清单可能短暂不一致：列表显示索引版本，确认弹窗显示真实清单版本与提交，安装仍以真实内容为准。
- 索引请求只吃 raw 限额；但安装仍走 API（每插件约 5 次），连续安装多个插件时可能触及匿名 60 次/小时，沿用现有 `rateLimited` 提示。
- 商店页不复制 `PluginRow`：已安装列表才有启用开关/卸载菜单，商店行只做安装与状态展示，避免同一个控件承担两种语义。
