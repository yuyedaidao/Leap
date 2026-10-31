# Leap 开源到 GitHub 计划（无官网版）

## Context

Leap（macOS 26+ / Apple Silicon 快速启动器）目前在 `gitee.com/padding/leap`，要开源到 GitHub，**同时砍掉官网，分发完全依托 GitHub**：

- **源码仓库即发行仓库**：`yuyedaidao/Leap`（用户指定，已确认未被占用），安装包以该仓库 Releases 形式提供
- **不再使用**原计划的独立下载仓库 `yuyedaidao/leap-releases`

gh 已登录 `yuyedaidao`（scope 含 `repo`）。

## 现状审计（已检查）

- 无 `LICENSE`；Git 历史 30 个提交（2026-09-17 起），作者 `wyq <wyqpadding@163.com>`；tracked 文件无密钥/敏感信息
- `Website/` 共 24 个 tracked 文件；网站文档仅被 `README.md`（第 55、81、83 行）引用
- `openspec/changes/add-official-website/` 是进行中变更（4/10 任务），从未归档，`openspec/specs/` 为空，删除无连带影响
- 分支：`main` + 本地 `codex/launcher-liquid-glass`（不推）
- 脚本中"独立下载仓库"假设：`publish-release.py:18` 与 `package-release.py:21` 的 `DEFAULT_REPO/DEFAULT_RELEASE_REPO = "yuyedaidao/leap-releases"`，及 `check_repo` 的自动建仓分支

## 已确认决策

| 项 | 决策 |
|---|---|
| 许可证 | MIT |
| Git 历史 | 原样推送 |
| 远端 | GitHub 为 origin，gitee 改名留作镜像 |
| 源码/发行仓库 | 同一个：`yuyedaidao/Leap`，DMG 挂其 Releases |
| 网站素材 | icon.png / share.png 移到 `Docs/media/` 复用 |
| 隐私说明 | 改写为 `Docs/Privacy.md` |
| WebsiteRelease.md / WebsiteValidation.md | 整篇删除 |

## Approach

先清理官网内容 + 改造发布脚本指向本仓库（commit 1），再加 LICENSE（commit 2），建仓推送。不新增 CI / CONTRIBUTING / issue 模板。

## Files to modify

**删除：**
- `Website/`（整个目录，24 文件）
- `Docs/WebsiteRelease.md`、`Docs/WebsiteValidation.md`
- `openspec/changes/add-official-website/`

**移动：**
- `Website/public/media/icon.png` → `Docs/media/icon.png`
- `Website/public/media/share.png` → `Docs/media/share.png`

**新增：**
- `LICENSE`（MIT，`Copyright (c) 2026 Yeqing Wang`）
- `Docs/Privacy.md`：改写自 `Website/src/pages/privacy.astro`，保留「宿主行为」「第三方插件」两节；「官网与下载」一节改为描述 GitHub 仓库与 Releases 下载

**编辑：**
- `Scripts/publish-release.py`：
  - `DEFAULT_REPO` → `"yuyedaidao/Leap"`
  - `check_repo`：删掉"默认下载仓库不存在时自动创建"分支，仓库不可访问即报错（发行仓库就是源码仓库，必然已存在）
  - `release()`：删掉对应的 `gh repo create` 兜底块
  - 发行标签 target：改为本地已验证的 `commit`（HEAD），标签即指向被构建的源码提交（原来指向下载仓库分支头，注释「发行标签不代表应用源码」随之失效）
  - release notes 文案「发行标签不代表应用源码。」→「发行标签指向本次发行的源码提交。」
  - `--repo` help 文案去掉"独立公开下载仓库"表述
- `Scripts/package-release.py`：
  - `DEFAULT_RELEASE_REPO` → `"yuyedaidao/Leap"`
  - 第 74 行错误信息「必须与官网的 macOS 26.0 一致」→「必须是 macOS 26.0」
  - 第 225 行结尾提示去掉「更新 Website/release.json」，改为上传 Release 后完成安装验收
- `README.md`：
  - 顶部加图标（`Docs/media/icon.png`）
  - 发布章节：「发布到 GitHub 下载仓库」→「以 Release 发布到本仓库」；删去发行手册/官网两条死链，相关文档加 `[隐私说明](Docs/Privacy.md)`
  - 第 77 行「一旦用于官网」→「一旦公开发布」
  - 加「下载」小节：指向 `https://github.com/yuyedaidao/Leap/releases`（注明正式版尚未发布时先自行构建）
  - 加 `## License` 小节
- `.gitignore`：删第 14–18 行 Website 相关五条

## Steps

- [ ] 1. 删除 `Website/`、两篇网站文档、`openspec/changes/add-official-website/`
- [ ] 2. 移动两张媒体图到 `Docs/media/`；新增 `Docs/Privacy.md`
- [ ] 3. 编辑 `Scripts/publish-release.py`（仓库指向 + target 语义）、`Scripts/package-release.py`（仓库指向 + 两处文案）、`README.md`、`.gitignore`
- [ ] 4. 验证：`python3 -m unittest discover -s Tests/Release -v`（发行脚本测试）；`git grep -in "leap-releases\|官网\|Website/"` 复查无残留；`swiftlint`
- [ ] 5. commit 1：`chore: 移除官网内容，发行切换到源码仓库 Releases`
- [ ] 6. 新增 `LICENSE` + README License 小节；commit 2：`docs: 添加 MIT 许可证`
- [ ] 7. `git remote rename origin gitee`
- [ ] 8. `gh repo create yuyedaidao/Leap --public --source=. --remote=origin`
- [ ] 9. `git push -u origin main`
- [ ] 10. `gh repo edit` 设描述与 topics（`macos` `swift` `swiftui` `launcher`）
- [ ] 11. （手动）GitHub 仓库 Settings → Social preview 上传 `Docs/media/share.png`

## Verification

- 无痕窗口访问 `https://github.com/yuyedaidao/Leap`：公开可读、LICENSE 识别为 MIT、README 图标正常渲染
- `git clone` 到临时目录 → `./Scripts/prepare-runtimes.sh && tuist generate && xcodebuild build` 验证全新克隆可构建
- 仓库内无 `leap-releases` / `官网` / `Website/` 残留引用（git 历史中保留属正常）

## 不在本计划内

- CI、CONTRIBUTING、issue/PR 模板
- gitee 仓库后续同步或删除（保留现状）
- 首次正式发行（依赖 Developer ID 证书与公证凭据，另一条线；届时 `./Scripts/publish-release.py` 即发布到本仓库 Releases）
