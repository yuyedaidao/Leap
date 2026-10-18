# Leap 官网与应用发行手册

首发目标：简体中文、macOS 26+、Apple Silicon；安装包通过独立 GitHub 下载仓库分发。网站仍通过 EdgeOne Pages 发布，COS 可作为手动分发渠道；网站先备案，再公开上线。

## 一键发布到 GitHub

入口是 `Scripts/publish-release.py`，需要在 Apple Silicon Mac 上安装 Xcode 命令行工具、Tuist、SwiftLint、Python 3.9+ 和 GitHub CLI。应用版本与构建号继续由 `Project.swift` 管理，不需要另写版本配置。

只需本地安装包时使用 `python3 Scripts/publish-release.py --local-only --test`。此模式不需要 GitHub 登录或发行证书，不创建远端仓库或发布版本；允许保留未提交改动，并将已有跟踪文件的补丁存入本次产物目录的 `source.patch`。新增源码文件须先纳入 Git 跟踪，补丁才会包含它们。仍完整执行运行时准备、Release 构建、单元测试、脚本测试和签名验证，生成可拖入“应用程序”的测试 DMG；未经 Apple 公证，不能承诺下载后直接打开。元数据标注 `notarized: false`，不伪造下载地址。正式发行仍要求干净工作区、Developer ID 与公证配置。

首次准备：

1. 执行 `gh auth login --hostname github.com`，登录有下载仓库写入权限的账号。
2. 将要发行的代码、脚本和文档提交，确保 `git status --short` 为空。脚本不会自动提交、推送或清理源码。
3. 默认公开下载仓库为 `yuyedaidao/leap-releases`。只有登录账号为 `yuyedaidao` 且默认仓库不存在时，脚本才会自动创建带 README 的公开仓库；不会传入当前源码目录或推送源码。其他目标通过 `--repo owner/repo` 指定，需要提前创建公开下载仓库并授予写入权限。
4. 正式发行准备 Developer ID Application 证书与私钥，执行 `xcrun notarytool store-credentials LeapNotary`，根据交互提示将公证凭据保存到钥匙串。

```sh
# 未公证测试包：显式选择，自动标记为预发布
./Scripts/publish-release.py --test

# 正式包：唯一的 Developer ID Application 证书会自动选择
./Scripts/publish-release.py

# 多张证书或使用其他公证配置时，在本机 Shell 中设置
export LEAP_SIGN_IDENTITY='Developer ID Application: 你的证书名称 (TEAMID)'
export LEAP_NOTARY_PROFILE='LeapNotary'
./Scripts/publish-release.py --repo owner/leap-releases --notes-file /path/to/notes.md
```

缺少正式证书或公证配置时停止，不会静默改成测试包。测试包采用临时签名，不经过 Apple 公证，可能被 Gatekeeper 拦截；不能承诺下载后直接打开。

脚本依次准备运行时、安装 Tuist 依赖、生成工程、检查 SwiftLint、构建 arm64 Release、使用 Debug 配置运行 `LeapTests` 和发行脚本测试，再打包。单测的 `@testable` 导入需要 Debug 的测试支持；Debug 和 Release 的产品目录独立，打包始终读取 Release。依赖安装后锁文件若发生变化，必须先核实、提交锁文件并重新运行。SwiftLint 检查本次验证范围内的应用源码、单测和工程描述，不扫描生成代码、依赖或未运行的 UI 测试。构建期间 HEAD 改变也会停止。

本地产物在 `build/releases/run-*/`，包括构建日志、DerivedData、DMG、候选发行 JSON、`SHA256SUMS.txt` 和发行说明。正式包沿用 `Leap-<版本>-arm64.dmg`；测试包为 `Leap-<版本>-arm64-test.dmg`。元数据格式与官网一致，但测试包元数据不能用于正式下载入口。

正式标签为 `v<版本>`，测试标签为 `v<版本>-test.<构建号>`。例如当前版本对应 `v1.2.0` 或 `v1.2.0-test.3`。同一标签已有发行版或标签就停止；下一轮测试需增加构建号，下一次正式发行需增加版本。标签指向下载仓库的默认分支提交，发行说明单独记录实际应用源码提交；GitHub 提供的源码归档仅含下载仓库内容。

上传时先创建草稿，上传 DMG、候选 JSON 和 SHA256 文件，再通过登录的 CLI 下载全部附件、核对字节数和 SHA256，最后自动公开。测试版不会替换最新正式版。成功后终端输出发行页面、下载地址和本地产物目录；脚本不自动更新官网、部署网站或上传 COS。

## GitHub 发布失败恢复

- 构建或公证失败：查看本次目录的 `build.log`，修复原因后重新执行。未完成打包时不会创建下载仓库或 Release。
- 上传或回读失败：保留本次目录，登录 GitHub 检查对应草稿。脚本不会自动删除草稿、标签或已有附件，也不会覆盖附件。
- 给草稿补充缺少的附件，可使用 `gh release upload <标签> <缺少的本地文件> --repo owner/repo`。若附件内容不正确，需要先在 GitHub 手动删除错误附件，再上传原本次目录中正确的文件；不要使用覆盖选项替换已经公开的版本。
- 将草稿全部附件下载到新的空目录：`gh release download <标签> --repo owner/repo --dir /path/to/empty-directory`。在下载目录执行 `shasum -a 256 -c SHA256SUMS.txt`，同时将 JSON 和校验文件的大小与 SHA256 和本地产物逐一比较。DMG 大小及 SHA256 还须匹配候选 JSON。
- 全部通过后，正式版执行 `gh release edit <标签> --repo owner/repo --draft=false --prerelease=false --latest=true`；测试版使用 `--prerelease=true --latest=false`。若公开请求超时，先查询 GitHub 状态，避免把已经公开的发行版当作失败草稿处理。
- 第一次公开发行仍需完成下面的安装包验收。发现问题时先撤下下载入口，发布新版本修复，不能替换原版本安装包。

## 发布前需要准备

1. 一个由用户持有的域名，完成用于大陆托管的 ICP 备案。记录主体、备案号及审核状态，不在仓库存储证件。
2. EdgeOne Pages 项目、COS 存储桶和 HTTPS 下载域名。网站域名及下载域名归于同一主域，分别配置 DNS 和有效证书。
3. 有效的 **Developer ID Application** 证书与对应私钥。Apple Development、Apple Distribution 证书不能替代它用于站外分发。
4. 钥匙串中的 `notarytool` 公证配置。通过 `xcrun notarytool store-credentials` 的交互提示保存凭据，不把密码、私钥或云服务密钥写进脚本、版本库或提交记录。

## 构建与签名公证

在仓库根目录准备运行时并生成工程，然后构建 Release：

```sh
./Scripts/prepare-runtimes.sh
tuist generate
xcodebuild build -workspace Leap.xcworkspace -scheme Leap \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/leap-release-build CODE_SIGNING_ALLOWED=NO
```

运行 `python3 Scripts/package-release.py --help` 查看参数。传入构建的 `Leap.app`、钥匙串中完整的 Developer ID Application 名称、公证配置名称、未使用的输出目录，以及已确认的 HTTPS 版本化 DMG 下载地址。

工具会在临时副本中执行以下流程，不修改原始构建：

1. 检查 bundle ID、版本、系统要求和 arm64 运行时；拒绝 Debug/预览构建。
2. 从内部 Mach-O 代码向外签名，开启 Hardened Runtime。只为 Node 添加 JIT 所需授权，为宿主添加 Apple Events 授权；不继承调试授权。
3. 验证嵌套签名，提交应用 ZIP 公证，确认 Accepted 后给应用装订公证票据并检查 Gatekeeper。
4. 制作带“应用程序”快捷方式的压缩 DMG，签名、公证、装订，验证磁盘映像与 Gatekeeper。
5. 全部成功后输出 `Leap-<版本>-arm64.dmg` 和候选发行 JSON。失败即停止，不发布未验证产物、不覆盖已有版本文件。

脚本需要访问钥匙串、Apple 公证服务及系统签名工具。首次运行仍必须做完整发行验收：嵌套 Python/Node 的实际运行不能由单元测试代替。

打包时仅在发行副本中移除 Python Tcl/Tk 框架失效的 `PrivateHeaders` 开发头文件链接，避免深度验签失败；原始构建与有效链接不受影响。同时将 Python 扩展与动态库中的系统 Python 绝对引用修正为包内相对路径；缺少目标库就停止。在签名后的副本运行 Node 表达式，并用隔离模式加载 Python SSL、SQLite，避免开发机环境掩盖包内依赖缺失。Python 检查和宿主执行均禁止写入字节码缓存，检查后再次验签，防止运行解释器破坏资源封印。签名扫描先检查 Mach-O 魔数，避免为 Python 的大量文本文件逐一启动外部进程。

## 安装包验收

- 在另一台满足系统要求、没有开发环境的 Apple Silicon Mac 下载 DMG，检查浏览器下载的隔离属性下正常安装与打开，无签名或公证拦截。
- 确认拖入“应用程序”、首次启动、默认 ⌥⌘L、应用搜索与打开可用。
- 安装仓库中的文本转换、数字枚举和 Python 示例，验证随包 Node/Python，测试 Shell 插件。
- 验证插件退出、复制、网页交互和需要授权的系统能力；拒绝授权时应有明确反馈。
- 验证从旧版更新保留本地数据。保留原安装包及哈希，不覆盖旧版本地址。

只有完成这些步骤才把候选 JSON 用作 `Website/release.json`。

## 上传 COS，先包后站

1. 按 `releases/<版本>/Leap-<版本>-arm64.dmg` 保存安装包；保持 URL 不可变，桶不开启匿名写入。
2. 配置已备案下载域名、HTTPS、合适的下载 Content-Type / Content-Disposition，并检查安装包可访问。
3. 从下载域名重新下载文件，用 `shasum -a 256` 核对候选 JSON；同时核对文件字节数。COS ETag 不作为 SHA256 替代。
4. 完成安装验收后，更新 `Website/release.json`。不要在网站代码里增加第二个下载 URL。

## EdgeOne Pages 手动部署

首次使用手工上传静态产物，减少自动化与外部仓库集成成本：

1. 在本机进入 `Website/`，运行 `npm ci`、`npm run check`、`npm test`。
2. 在环境中设置已确认的 `SITE_URL` 和 `ICP_NUMBER`，运行 `npm run build:production`。记录 Git 提交、应用版本、元数据和构建时间。
3. 保存 `dist/` 作为本次部署产物，上传到 EdgeOne Pages 静态部署项目。控制台操作按当前服务界面执行。
4. 绑定已备案域名，配置 DNS 和有效 HTTPS 证书。备案未完成前不能公开部署；不要使用平台预览域名替代备案上线。
5. 验证首页、指南、开发者文档、隐私、404、robots、sitemap、分享图片、视频及备案链接。确认正式页面存在正确 canonical。
6. 从中国大陆网络用 Safari/Chrome 和手机访问，检查 HTTPS、页面速度、视频、下载完成、大小与 SHA256。

EdgeOne Pages 配置须明确使用 `build:production` 或只上传通过该命令生成的产物。普通本地构建不代表获得发布资格。部署配置和控制台账号不能写入仓库。

## 回滚

保留上一版的静态产物、对应 `release.json` 和版本化 DMG。出问题时恢复上一版 EdgeOne 部署，核对下载链接指向上一版包并清理必要缓存。撤回有问题版本的官网入口，保留内部排查记录；不要替换同 URL 文件来“修复”已发布版本。

## 参考

- [Apple 发行签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [EdgeOne Pages 部署概述](https://edgeone.cloud.tencent.com/pages/document/175191784523485184)
- [COS 自定义域名与 CDN](https://cloud.tencent.com/document/product/436/18670)
