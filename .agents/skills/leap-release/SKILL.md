---
name: leap-release
description: 发布 Leap macOS 应用的新版本：升版本号、跑发版脚本、在 GitHub Releases 公开发行并更新 Homebrew Tap。适用于「发版」「发布 0.0.x」「升级版本并发布」等请求。
---

# 发布 Leap 新版本

正常路径只有四步，其余是失败兜底。原理与参数细节见 `Docs/Development.md` 的「发布」章节，不要在这里重复抄写。

## 前置条件先核对

- 工作区干净且**提交已推送到 `origin`**：`gh release create --target <sha>` 只接受远端已知的提交，未推送会在构建公证十分钟后才以 `target_commitish is invalid` 失败（脚本现已在预检阶段拦截）。
- 本机具备 `Developer ID Application` 证书、`LeapNotary` 公证配置、`gh` 登录、钥匙串账户 `com.padding.leap.sparkle` 的 Sparkle 私钥。`Project.swift` 的 `SUPublicEDKey` / `SUFeedURL` 不要改。

## 第一步：升版本

`Project.swift` 两行同时改：`CFBundleShortVersionString`（如 0.0.5）、`CFBundleVersion`（+1）。构建号必须大于上一份 `appcast.xml` 里的 `sparkle:version`，否则脚本拒绝正式发行。

## 第二步：提交并推送

按主题分提交（功能、chore: 发布 Leap x.y.z），然后 `git push origin main`。发版脚本要求工作区干净，也不会替你提交。

## 第三步：写说明并发行

更新说明写用户能感知的变化，三到五条，不要写内部实现：

```sh
cat > /tmp/notes-x.y.z.md <<'EOF'
- ...
EOF
./Scripts/publish-release.py --notes-file /tmp/notes-x.y.z.md
```

一条命令完成运行时准备、Tuist 生成、SwiftLint、Release 构建、单测、打包签名公证、生成 appcast 并发布，约十分钟；长任务日志在 `build/releases/run-<id>/build.log`。只想出包不发布时用 `--local-only --test`。

## 失败兜底

- 下载、上传阶段的失败不要重跑整脚本（会重新公证十分钟）。用 `build/releases/run-<id>/` 里已有的真实产物手工补齐剩余步骤：
  `gh release create vX.Y.Z --repo yuyedaidao/Leap --target <sha> --draft --title "Leap vX.Y.Z" --notes-file <notes>`（创建后删掉 `untagged-*` 草稿）→ `gh release upload` 四个附件 → `gh release download` 到临时目录逐字节比对 → `gh release edit --draft=false --latest=true`。
- 附件固定四个：`Leap-<版本>-arm64.dmg`、`appcast.xml`、`Leap-<版本>-release.json`、`SHA256SUMS.txt`。不要删除或覆盖远端已公开的附件，公开后同一 URL 的文件不能替换。

## 第四步：更新 Homebrew Tap

`yuyedaidao/homebrew-tap` 的 `Casks/leap.rb` 只改 `version` 和 `sha256`（取自 `SHA256SUMS.txt`），仓库约定提交信息为 `leap <版本>`：

```sh
cd /tmp && rm -rf tap-edit && git clone --quiet https://github.com/yuyedaidao/homebrew-tap.git tap-edit && cd tap-edit
# 改 Casks/leap.rb 的 version / sha256
git commit -qam "leap X.Y.Z" && git push origin HEAD
```

## 交付前验收

1. `curl -sL https://github.com/yuyedaidao/Leap/releases/latest/download/appcast.xml` 里 `sparkle:version` 是新构建号、enclosure 指向新 DMG、带 `edSignature`。
2. `gh release view vX.Y.Z --json tagName,isDraft,isPrerelease,assets` 为已公开发行、四个附件齐全、`latest` 指向它。
3. Tap 的 `sha256` 与实际下载的 DMG 哈希一致：`curl -sL <DMG url> | shasum -a 256`。
4. 报告里给出 Release 链接、DMG 哈希、Tap 提交号；`gitee` 镜像默认不同步，需要时询问用户。
