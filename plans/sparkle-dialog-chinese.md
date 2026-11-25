# 让 Sparkle 更新弹窗跟随中文

## Context

Leap 面向中国用户，但「检查更新」弹出的对话框（标题、`安装更新 / 跳过此版本 / 稍后提醒` 等按钮、下载进度窗口、`已是最新版本` 提示）显示英文。

原因不在 Sparkle 缺中文翻译：`Sparkle.framework/Resources` 里自带 `zh_CN.lproj`（另有 `zh_TW` / `zh_HK`），`Sparkle/zh_CN.lproj/Sparkle.strings` 是完整简体中文。

真正原因在宿主应用没声明任何本地化。macOS 查框架资源时会把**子 bundle 的可用语言裁到主 app 声明的语言**里，主 app 一个 `.lproj` 都没有、`CFBundleLocalizations` 也没写，只剩 `CFBundleDevelopmentRegion = en`，于是 Sparkle 的英文（Base/en）被选中。

当前证据：

- `Leap.xcodeproj/project.pbxproj:744` 的 `knownRegions = (Base, en)`。
- 已发布产物 `Leap.app/Contents/Resources` 下没有任何 `.lproj`，`Info.plist` 只有 `CFBundleDevelopmentRegion = en`，无 `CFBundleLocalizations`。
- 语言映射本身没问题：`Bundle.preferredLocalizations(from: ["en","zh_CN","zh_TW"], forPreferences: ["zh-Hans"])` → `["zh_CN"]`，即声明 `zh-Hans` 后 Sparkle 的 `zh_CN.lproj` 会被命中。

预期结果：系统语言为简体中文时，Sparkle 全部原生界面显示简体中文；英文系统仍回落到英文，不改动现有视觉与交互。

## Approach

在 `Project.swift` 的 `Leap` target Info.plist 里声明 `CFBundleLocalizations = ["zh-Hans"]`，一行改动，不新增资源文件。

为什么不选其他做法：

- **加 `zh-Hans.lproj/Localizable.strings`**：效果相同，但要为一个纯声明新增目录和文件；app 自身字符串是写死的中文，没有可翻译内容。只有想在系统设置「语言与地区 → 应用程序」里把 Leap 显示为简体中文并支持逐 app 切语言时才需要，当前不需要。
- **自写 `SPUUserDriver` 或替换 Sparkle 界面**：等同于重做官方弹窗，维护成本远高于收益。
- **在 app 里写 `AppleLanguages` 或改 `CFBundleDevelopmentRegion`**：`AppleLanguages` 是用户级全局键，改它会影响全系统；`CFBundleDevelopmentRegion` 只改回落语言，绕不开上面的裁切规则。

保持 `CFBundleDevelopmentRegion = en` 不变：中文系统按 `CFBundleLocalizations` 命中，英文/其他系统合理回落到英文。

## Files to modify

- `Project.swift` — `Leap` target 的 `infoPlist: .extendingDefault(...)` 增加 `"CFBundleLocalizations": ["zh-Hans"]`。
- `Docs/Development.md`（可选）— 「发布」章节补一句：更新弹窗语言依赖 app 声明本地化，改动后需重新发行才生效。

## Reuse

- 现有 Info.plist 扩展机制：`Project.swift:32-44` 已用 `.extendingDefault(with:)` 注入 `SUFeedURL`、`SUPublicEDKey` 等键，同一个字典加一行即可，不引入新机制。
- Sparkle 自带 `zh_CN.lproj`（Sparkle 2.10.1，`Tuist/Package.swift:22`），无需自带翻译文件。
- 发行链路无需改动：`Scripts/package-release.py:57`、`Scripts/publish-release.py:115` 只读 Info.plist 的版本与 bundle id，不重写该文件。

## Steps

- [x] `Project.swift` 的 `Leap` Info.plist 增加 `"CFBundleLocalizations": ["zh-Hans"]`。
- [x] `tuist generate`（改的是工程描述，必须重新生成 `Leap.xcodeproj`）。
- [x] `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`。
- [ ] 确认产物信息：`plutil -p <Leap.app>/Contents/Info.plist` 含 `CFBundleLocalizations => [zh-Hans]`。
- [x] 视觉验收：见下节，截图交给用户确认效果后再提交。

## Verification

1. **构建与产物**：上面前三步；`plutil` 检查键存在。
2. **中文弹窗（关键）**：用 Debug 产物以中文偏好启动并触发检查：
   ```bash
   open -a <DerivedData>/Build/Products/Debug/Leap.app --args -AppleLanguages "(zh-Hans)"
   ```
   在设置里点「检查更新」。当前 1.1.1 已是最新，应看到简体中文的「您使用的已是最新版本」类提示，而改之前是英文。
3. **英文不回归**：同一份包用 `-AppleLanguages "(en)"` 启动，提示仍为英文。
4. **完整更新流程**：把 `SUFeedURL` 临时指向一份构建号更高的本地/测试 appcast（或用 `--test` 发一版测试包）走一遍「发现新版本 → 下载 → 安装」，确认标题、按钮、进度窗、失败提示均为中文。该步在真实发行前做一次即可。
5. `swiftlint`、`xcodebuild test -only-testing:LeapTests` 通过（本改动不涉及 Swift 逻辑，属回归确认）。

## 风险与注意

- 这是**界面语言类改动**：按 `AGENTS.md` 的视觉闸门，截图/现场确认由用户点头之前不 `git commit`、不 `git push`。
- 已发布版本无法回头改：1.1.1 及更早的更新弹窗仍是英文，只有**下一次发行**（如 1.1.2）才会带中文弹窗。
- 若以后要支持繁体，在数组里追加 `zh-Hant` 即可命中 Sparkle 的 `zh_TW`/`zh_HK`。
- 更新说明文字本身已是中文（`generate_appcast --embed-release-notes` 写入的是 `release-notes.md` 内容），不受此改动影响。
