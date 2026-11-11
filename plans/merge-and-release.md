# 合并插件商店改动到 main 并发布 Leap 0.0.6

## Context

用户已真机验证本轮插件商店体验修补（图标、详情、底部索引时间、安装/更新弹窗），要求合并到主分支并发布新版本，同时确认插件仓库也在主分支上。

现状核对（只读）：

- Leap 仓当前在 `feature/plugin-store`；工作区 11 个修改 + 1 个新增（`Sources/Leap/PluginStoreDetailsView.swift`）+ 2 份未跟踪计划文档。`origin/main`（`dc015ed`）是本分支祖先，**无分叉**，合并是 fast-forward。
- `git log origin/main..HEAD` 只有 5 个提交（商店核心 `d59c6ca`、商店页面 `f4b7a33`、文档 2 个、错误文案修复 `9ed489a`），所以 0.0.5 用户升级后才第一次看到插件商店。
- 版本仍是 `Project.swift` 的 `0.0.5` / `5`；最新公开发行 `v0.0.5`（build 5，四个附件齐全、`latest` 指向它），所以新构建号必须 ≥ 6。
- 插件仓库 `/Users/wyq/Work/Project/2026/LeapPlugins`：`HEAD == origin/main == b9cf79e`，工作区干净，`store.json` 已带 `icon`，`node --test` 32/32 通过。**「插件仓库改到主仓库」已满足**，只剩远端历史分支 `origin/feature/store-index`（已合并）。
- 发布前置条件已核对：`gh` 登录 `yuyedaidao`；`LeapNotary` 公证配置可用（最近一次 `Accepted`）；本机唯一 `Developer ID Application: Yeqing Wang (97F5F2AF3C)`，`publish-release.py` 会自动选用（`LEAP_SIGN_IDENTITY` 无需设置）；`origin/feature/plugin-store` 已在远端。

用户已定：版本 **0.0.6 / 构建号 6**；合并后删除已合并的远端分支；`plans/` 下两份计划文档入库。

## Approach

走 `.agents/skills/leap-release/SKILL.md` 的正常路径，不发明新流程：

1. **按主题提交**：文件级拆分，不做逐 hunk 拆（避免 `git add -p` 出错）。四条：商店 UI/索引、安装弹窗行为、测试、文档。
2. **升版本**：`Project.swift` 的 `CFBundleShortVersionString` → `0.0.6`、`CFBundleVersion` → `6`，单独一个 `chore: 发布 Leap 0.0.6` 提交。
3. **fast-forward 合并**：`git checkout main && git merge --ff-only feature/plugin-store && git push origin main`。工作区在推送后必须干净，`publish-release.py` 用当前 `HEAD` 作为 `--target`，脚本里的 `require_clean` / `require_pushed` / `check_update_build` 会再校验一次。
4. **发说明并发行**：`./Scripts/publish-release.py --notes-file /tmp/notes-0.0.6.md`，盯 `build/releases/run-<id>/build.log`（约 10 分钟）。
5. **更新 Homebrew Tap**：`Casks/leap.rb` 只改 `version` 与 `sha256`（取自 `SHA256SUMS.txt`），提交信息 `leap 0.0.6`。
6. **收尾清理**：删除已合并的远端分支 `origin/feature/plugin-store`（Leap）与 `origin/feature/store-index`（LeapPlugins）。
7. **验收**：远端 appcast、Release 四个附件与 `latest`、Tap 哈希三者对齐后汇报。

### 提交拆分（在 `feature/plugin-store` 上）

| # | 提交信息 | 文件 |
|---|---|---|
| 1 | `feat(store): 商店条目显示图标并可点击查看详情` | `Sources/LeapCore/PluginStoreIndex.swift`、`Sources/Leap/PluginStorePage.swift`、`Sources/Leap/PluginStoreDetailsView.swift`、`Sources/Leap/PluginSettingsPage.swift`、`Sources/Leap/LeapSettingsView.swift`、`Sources/Leap/PluginDetailsView.swift` |
| 2 | `fix(store): 商店安装与更新改用安装弹窗` | `Sources/Leap/PluginInstallationModel.swift`、`Sources/Leap/RemotePluginInstallView.swift` |
| 3 | `test(store): 覆盖图标解析、商店安装状态与商店导航` | `Tests/LeapTests/PluginStoreIndexTests.swift`、`Tests/LeapTests/PluginInstallationModelTests.swift`、`Tests/LeapUITests/PluginStoreUITests.swift`、`Tests/LeapUITests/PluginDetailsUITests.swift` |
| 4 | `docs: 插件商店体验修补与发版计划` | `plans/plugin-store-ux-polish.md`、`plans/merge-and-release.md` |
| 5 | `chore: 发布 Leap 0.0.6` | `Project.swift` |

### 更新说明草稿（用户可感知，发布时用）

```
- 新增插件商店：在插件页打开商店即可浏览官方插件并一键安装
- 商店插件显示图标，点条目能查看详情；已安装的插件直接进入原插件详情
- 插件安装与更新统一在弹窗里显示进度与确认，更新完成后条目立刻变为「已安装」
- 商店索引更新时间固定在页面底部
- 插件详情不再显示本机安装路径
```

## Files to modify

代码（已通过测试，待提交）：

- `Sources/LeapCore/PluginStoreIndex.swift`
- `Sources/Leap/PluginStorePage.swift`
- `Sources/Leap/PluginStoreDetailsView.swift`（新增）
- `Sources/Leap/PluginSettingsPage.swift`
- `Sources/Leap/LeapSettingsView.swift`
- `Sources/Leap/PluginInstallationModel.swift`
- `Sources/Leap/RemotePluginInstallView.swift`
- `Sources/Leap/PluginDetailsView.swift`
- `Tests/LeapTests/PluginStoreIndexTests.swift`、`PluginInstallationModelTests.swift`
- `Tests/LeapUITests/PluginStoreUITests.swift`、`PluginDetailsUITests.swift`
- `plans/plugin-store-ux-polish.md`、`plans/merge-and-release.md`

发版：

- `Project.swift`：`0.0.5`/`5` → `0.0.6`/`6`
- 外部仓库 `yuyedaidao/homebrew-tap`：`Casks/leap.rb` 的 `version`、`sha256`

插件仓库 `LeapPlugins`：**无需改动**（已在 `main`，`b9cf79e`），只删远端历史分支。

## Reuse

- `.agents/skills/leap-release/SKILL.md`：发版四步、验收清单与失败兜底（`gh release create --draft` + 上传/比对/转正）。
- `Scripts/publish-release.py`：预检（`require_clean`、`require_pushed`、`require_new_tag`、`check_update_build`）、Release 构建、`swiftlint Sources Tests/LeapTests Project.swift`、`-only-testing:LeapTests`、`Tests/Release` 单测、打包签名公证、appcast 生成与发布，一条命令完成。
- 上一版 Tap 改动模式：只改 `version`/`sha256`，提交信息 `leap X.Y.Z`。
- `plans/` 既有文档已入库（如 `plugin-store.md`），本次两份同风格提交。

## Steps

- [x] 1. 按上表第 1–2 条提交功能改动（`git add <显式文件列表>`，不用 `git add -A`，确保不误带 `build/`、`Leap.xcodeproj`、`plans/merge-and-release.md` 之外的杂项）。
- [x] 2. 提交测试（第 3 条）与文档（第 4 条）。
- [x] 3. 改 `Project.swift` 为 `0.0.6`/`6`，提交 `chore: 发布 Leap 0.0.6`；确认 `git status` 干净。
- [x] 4. `git checkout main` → `git merge --ff-only feature/plugin-store` → `git push origin main`；再确认 `git rev-parse HEAD` 与 `git log origin/main -1` 一致。
- [ ] 5. 写 `/tmp/notes-0.0.6.md`（用上面的草稿），运行 `./Scripts/publish-release.py --notes-file /tmp/notes-0.0.6.md`。
- [ ] 6. 若脚本在下载/上传阶段失败：不重跑整脚本，按 SKILL 用手工 `gh release create --draft` + `gh release upload` + 逐字节比对 + `gh release edit --draft=false --latest=true` 补齐。
- [ ] 7. 更新 `yuyedaidao/homebrew-tap` 的 `Casks/leap.rb`（`version`/`sha256`），提交 `leap 0.0.6` 并推送。
- [ ] 8. 删除已合并远端分支：`git push origin --delete feature/plugin-store`、`git -C /Users/wyq/Work/Project/2026/LeapPlugins push origin --delete feature/store-index`。
- [ ] 9. 按验收清单核对并汇报（Release 链接、DMG SHA256、Tap 提交号；Gitee 镜像默认不同步）。

## Verification

- 发布脚本自身会执行：`swiftlint`、Release 构建（arm64）、`xcodebuild test -only-testing:LeapTests`、`Tests/Release` 单测、签名与公证。
- `curl -sL https://github.com/yuyedaidao/Leap/releases/latest/download/appcast.xml`：`sparkle:version` = `6`、enclosure 指向 `Leap-0.0.6-arm64.dmg`、带 `edSignature`。
- `gh release view v0.0.6 --json tagName,isDraft,isPrerelease,assets`：已公开发行、四个附件（DMG / `appcast.xml` / `-release.json` / `SHA256SUMS.txt`）、`latest` 指向它。
- `curl -sL <DMG url> | shasum -a 256` 与 Tap `sha256` 一致。
- 插件仓库：`git -C /Users/wyq/Work/Project/2026/LeapPlugins log --oneline -1 origin/main` = `b9cf79e`；`curl -s https://raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json | grep -c '"icon"'` = 3。
- 上游远端分支已删：`git ls-remote --heads origin feature/plugin-store` 为空。

## Risks

- 公证 + 构建约 10 分钟，期间不能有工作区改动（脚本中途会 `require_clean` 并校验 `HEAD` 未变）。
- 公开发布后同一 URL 的附件不可替换，`require_new_tag` 会阻止重复 tag；真出问题只能发新版本号。
- 0.0.5 → 0.0.6 是插件商店首次面向用户，商店图标依赖 `raw.githubusercontent.com` 直连，被墙时回落符号占位（不影响列表与安装）。
- 删除 `origin/feature/plugin-store` 后本地分支保留；若发版后仍需修补，只能从 `main` 开新分支（这正是期望行为）。
- Gitee 镜像默认不同步，本计划不含；需要时另外询问。
