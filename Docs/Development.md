# Leap 构建与发版说明

本文供从源码构建、测试和发布 Leap 的维护者使用。下列命令均从仓库根目录执行。

## 环境要求

- macOS 26 或更高版本，Apple Silicon
- Xcode 与命令行工具
- [Tuist](https://tuist.dev)：`Leap.xcodeproj` / `Leap.xcworkspace` 不入库，改动 `Project.swift` 后需重新生成
- SwiftLint
- Python 3.9+：运行打包脚本

## 构建与测试

```sh
tuist generate
xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'
swiftlint
```

首次构建前准备随包 Node/Python 运行时；发布脚本也会自动调用它：

```sh
./Scripts/prepare-runtimes.sh
```

## 应用更新与发行签名

正式发行除现有签名、公证配置外，还需本机钥匙串中的 Sparkle 密钥，账户为 `com.padding.leap.sparkle`，公钥必须匹配 `Project.swift` 的 `SUPublicEDKey`。首次配置使用依赖中的 `Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.padding.leap.sparkle`；已有发行用户后不能随意换钥匙。私钥不要提交或写入构建日志，请通过安全方式备份钥匙串。

发布脚本对最终公证 DMG 生成带签名的 `appcast.xml`，一起上传并回读校验后才公开；公开后还会匿名检查 latest 订阅与本次产物一致。每次正式发行需递增版本和 `CFBundleVersion`；测试版不发布正式订阅。更新源为本仓库最新正式 Release 的 `appcast.xml` 附件，修改发行仓库时也需同步应用订阅地址。

## 一键打出 DMG

入口是 `Scripts/publish-release.py`，一条命令完成运行时准备、Tuist 生成、SwiftLint、Release 构建、单测和 DMG 打包。

### 本地测试包（推荐）

```sh
python3 Scripts/publish-release.py --local-only --test
```

不需要 GitHub 登录、Developer ID 证书或公证凭据；允许带未提交改动打包（改动记录在产物目录的 `source.patch`）。`--local-only` 必须与 `--test` 同时使用。

产物在 `build/releases/run-<id>/`：

- `Leap-<版本>-arm64-test.dmg`：测试安装包
- `Leap-<版本>-release.json`：候选发行元数据
- `SHA256SUMS.txt`、`release-notes.md`、`source.patch`
- `build.log`：完整构建与测试日志

`build/` 已被 `.gitignore` 忽略，产物不要提交入库。测试包只做临时签名、未经过 Apple 公证，其他 Mac 上可能被 Gatekeeper 拦截，不能作为正式下载入口。

### 正式发行

```sh
./Scripts/publish-release.py
```

需要有效的 Developer ID Application 证书与 `LeapNotary` 公证配置、`gh` 登录，且 Git 工作区干净。脚本会构建、签名、公证，并以 Release 形式发布到本仓库。

正式 Release 公开后，按 `SHA256SUMS.txt` 手动更新 [Homebrew Tap](https://github.com/yuyedaidao/homebrew-tap) 中 `Casks/leap.rb` 的 `version` 和 `sha256`。

## 只打包已有应用

`Scripts/package-release.py` 不构建应用，只对现成的 Release `Leap.app` 做签名、公证并生成 DMG，所有参数都有默认值：

```sh
# 测试包：自动查找最新 Release 构建，产物写入 ./build
python3 Scripts/package-release.py --test

# 正式包：自动选择唯一证书、LeapNotary 公证配置，并按版本生成默认下载地址
python3 Scripts/package-release.py
```

| 参数 | 默认值 |
| --- | --- |
| `app`（位置参数） | 最近的 Release 构建产物（`build/releases/run-*`、Xcode DerivedData、`/private/tmp/leap-release-build`） |
| `--identity` | 钥匙串中唯一的 Developer ID Application 证书 |
| `--notary-profile` | `LeapNotary` |
| `--output` | `./build` |
| `--download-url` | 按本仓库 Releases 与版本生成 |

需要覆盖时显式传入，例如 `python3 Scripts/package-release.py --test --output /tmp/leap-dmg`。钥匙串中有多张证书或找不到 Release 构建时必须显式指定对应参数。正式包的下载地址一旦公开发布，就不能再替换同一 URL 的文件。

## 插件开发资料

[插件开发指南](PluginDevelopment.md)提供清单、API 和示例。[README](../README.md#用-ai-创建第一个插件)提供 Skill 的快速安装命令。

默认安装到当前项目，加 `--global` 可在同一工具的其他项目中使用。也可以让 AI 在当前项目中执行这条命令，并指定安装目标，例如追加 `--agent claude-code -y`。如果没有 `npx`，可将 [Skill 目录](../skills/leap-plugin-development/) 复制到所用工具的 Skills 目录。
