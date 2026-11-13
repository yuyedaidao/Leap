# 发布 Leap 0.0.7

## Context

- 0.0.6（构建 6）已于 2026-11-11 公开发行，`appcast.xml` 的最新 `sparkle:version` 为 6。
- 本次唯一待发内容：修复「最近使用」在冷启动时被清空的问题（`Sources/Leap/LauncherModel.swift`、`Sources/LeapCore/RecentCommandStore.swift`、`Tests/LeapTests/LauncherShellTests.swift`，单测 143 项已通过）。
- 用户要求直接发新版本，按 `AGENTS.md` 约定自行完成提交、推送、升版本、发版脚本与 Tap 更新，不中途反问是否提交。

目标：发布 0.0.7（构建 7），GitHub Release 公开、Sparkle 订阅指向新包、Homebrew Tap 同步。

## Approach

严格按 `.agents/skills/leap-release/SKILL.md` 的四步走；版本策略为 `0.0.7` / `CFBundleVersion` `7`（必须大于上一份 appcast 的 6）。不新增任何功能代码。

## Files to modify

- `Sources/Leap/LauncherModel.swift`、`Sources/LeapCore/RecentCommandStore.swift`、`Tests/LeapTests/LauncherShellTests.swift` —— 已有修复，只需提交
- `Project.swift` —— `CFBundleShortVersionString` `0.0.6` → `0.0.7`，`CFBundleVersion` `6` → `7`
- `plans/release-0.0.7.md` —— 本计划（随发版一起提交）
- 外部仓库 `yuyedaidao/homebrew-tap` 的 `Casks/leap.rb` —— 只改 `version` 与 `sha256`

## Reuse

- `Scripts/publish-release.py`：一条命令完成运行时就绪、`tuist generate`、SwiftLint、Release 构建、单测、签名公证、生成 appcast、发布与线上订阅校验；脚本自动在说明末尾追加版本、构建号、源码提交与 `DMG SHA256`。
- 脚本内建预检：工作区干净（`require_clean`）、提交已推送（`require_pushed`）、标签/发行未被占用（`require_new_tag`），因此必须先提交并 push 再发版。
- 失败兜底用 `build/releases/run-<id>/` 的既有产物手工补 `gh release create/upload/edit`，不重跑整脚本。

## Steps

- [ ] 切换到 `main`（当前 `develop` 与 `main`、`origin/main` 同一提交 `7ba88c3`，无分叉）
- [ ] 按主题提交：`fix(launcher): 修复最近使用记录在启动时被误删`（三处源码+测试）、`docs: 增加 0.0.7 发版计划`
- [ ] 升版本：`Project.swift` 两行改为 0.0.7 / 7，提交 `chore: 发布 Leap 0.0.7`
- [ ] `git push origin main`
- [ ] 写更新说明 `/tmp/notes-0.0.7.md`（3 条用户可感知变化）：
  - 修复「最近使用」在每次重启后丢失插件记录的问题
  - 最近使用不再因为系统应用索引与插件加载先后顺序被清空
  - 输入搜索词时不再反复读写最近使用记录
- [ ] `./Scripts/publish-release.py --notes-file /tmp/notes-0.0.7.md`（后台跑，约 10 分钟，日志 `build/releases/run-<id>/build.log`）
- [ ] 更新 Tap：`Casks/leap.rb` 的 `version` 改 `0.0.7`、`sha256` 取本轮 `SHA256SUMS.txt`，提交信息 `leap 0.0.7`，push
- [ ] 汇总报告：Release 链接、DMG SHA256、Tap 提交号

## Verification

1. `curl -sL https://github.com/yuyedaidao/Leap/releases/latest/download/appcast.xml`：`sparkle:version` 为 `7`、`sparkle:shortVersionString` 为 `0.0.7`、enclosure 指向 `Leap-0.0.7-arm64.dmg`、含 `sparkle:edSignature`
2. `gh release view v0.0.7 --json tagName,isDraft,isPrerelease,assets`：已公开、四个附件齐全（DMG / appcast.xml / `Leap-0.0.7-release.json` / `SHA256SUMS.txt`）、`latest` 指向它
3. `curl -sL <DMG url> | shasum -a 256` 与 `SHA256SUMS.txt`、Tap 中的 `sha256` 三者一致
4. `git status --porcelain` 为空、`git log origin/main -1` 与发行标签指向同一提交

## Risks

- 公证与发布约 10 分钟且属外网操作；下载/上传阶段失败走手工补齐，不重跑公证。
- 已公开的附件不能被同名覆盖，任何返工都必须换新构建号（8）与新 tag。
- 同一版本号不能重复发行；`v0.0.7` 目前不存在（本地与远端 tags 只有 v0.0.1–v0.0.6）。
- Gitee 镜像本次不同步（已与用户确认），仅发布 GitHub Release 与 Homebrew Tap。
