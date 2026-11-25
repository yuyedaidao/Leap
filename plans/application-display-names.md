# 应用显示名对齐 Finder（含空白名称修复）

## Context

`cd` / `wx` 排序问题已修复并验证。本轮只处理**显示名**，用户实测截图暴露两处：

1. **同名副本无法区分**：`/Applications/Xcode-27.2.0.app`、`/Applications/Xcode-26.6.0.app` 在 Finder 里就是这两个带版本的名字，但搜索结果两行标题都是 `Xcode`。
   缓存实测（`~/Library/Application Support/Leap/application-index-v1.json`，version 8）两份条目都是 `{"name": "Xcode", "alternateNames": [], "bundleIdentifier": "com.apple.dt.Xcode"}`：两个包的 `CFBundleName` / `CFBundleDisplayName` / `CFBundleExecutable` 全是 `Xcode`，`Resources` 只有 `en.lproj` 且不含名称键。
2. **标题为空**：`/Applications/Copilot for Xcode.app` 缓存条目是 `{"name": "", "alternateNames": ["Copilot for Xcode"]}`。原因是该包 `CFBundleDisplayName` 是**空字符串**而不是缺失，`SystemApplication.swift:169-174` 的回退链只用 `??`，空串照样被采用。

两者同源：**标题取自 `CFBundleName`，而用户看到的是 Finder 的显示名**。用户的判断标准（已确认）：标题必须与 Finder 里看到的字一致。

期望结果（方案 A，用户已确认）：

| 应用 | Finder / 期望标题 |
| --- | --- |
| 计算器 `Calculator.app` | 计算器 |
| 访达 `Finder.app` | 访达 |
| 微信 `WeChat.app` | 微信 |
| 词典 `Dictionary.app` | 词典 |
| `Visual Studio Code.app`（`CFBundleName` = Code） | Visual Studio Code |
| `Xcode-27.2.0.app` / `Xcode-26.6.0.app` | Xcode-27.2.0 / Xcode-26.6.0 |
| `Copilot for Xcode.app` | Copilot for Xcode |

关于两份 Xcode：按方案 A，它们都没有当前系统语言（简体中文）的本地化名称，因此都落到**包名**，两行分别显示 `Xcode-27.2.0`、`Xcode-26.6.0`。只装了一份 Xcode 时同样显示 `Xcode-27.2.0`——规则按“Finder 显示什么”走，不按“是否重复”走。

检索质量不能退化：`name` 仍是检索主键，`code` 对 VS Code 保持一级命中，`xcode` 对两份 Xcode 保持首名前缀命中。

## Approach

### 1. 名称拆成“检索名”与“显示名”

`SystemApplicationDescriptor` 新增 `public let displayName: String?`（Codable，`init` 末尾带默认值 `nil`）：

- `name`（检索主键，保持现有回退链，仅增加空白过滤）：系统语言本地化名 → 其它语言本地化名 → 非空白 `CFBundleDisplayName` → 非空白 `CFBundleName` → 包名（去 `.app`）。因此 VS Code 的 `name` 仍是 `Code`、Xcode 仍是 `Xcode`，检索等级不变。
- `displayName`（显示用，即 Finder 规则）：系统语言本地化名 → 包名（去 `.app`）；与 `name` 相同时存 `nil`，由调用方回退到 `name`。
  - 计算器 / 访达 / 微信 / 词典 → `nil`（显示名等于 `name`）；
  - VS Code → `Visual Studio Code`，两份 Xcode → `Xcode-27.2.0` / `Xcode-26.6.0`，Copilot → `nil`（`name` 已是 `Copilot for Xcode`）。

### 2. “系统语言本地化名”的判定

现有 `localizedNames(in:)`（`SystemApplication.swift:187`）把 `Bundle.preferredLocalizations(from:forPreferences:)` 的结果排在前面，但该 API 在系统语言缺失时会回退到 `en`，无法区分“真匹配”与“回退”。因此按语言主码比较：

```swift
// zh-Hans-CN → 主码 zh；zh_CN / zh-Hans 命中，en 不命中
private func matchesPreferredLanguage(_ localization: String) -> Bool
```

`localizedNames(in:)` 改为返回 `(preferred: [String], others: [String])`，`preferred` 是“本地化文件语言命中系统语言且确实含名称键”的名字：

- Xcode 只有 `en.lproj`、且其中没有名称键 → `preferred` 为空 → 显示名落到包名；
- VS Code 有 `zh_CN.lproj` 但名称键缺失 → 同样落到包名；
- 计算器 / 访达 / 微信 / 词典 → `preferred` 非空 → 中文名。

### 3. 副标题不再显示 Bundle ID

用户确认：Bundle ID 对普通用户无意义。`LauncherItem.subtitle` 改为 `String?`：`.application` → `nil`（不显示副标题），`.plugin` → 插件名。

连同删除上一轮为“重复副本副标题”引入的脚手架：

- `LauncherItem.subtitle(duplicatedBundleIDs:)` → `var subtitle: String?`；
- `LauncherView.LauncherSearchResults.duplicatedBundleIDs` 与相关传参删除；
- `SystemApplicationDescriptor.duplicatedBundleIDs(in:)` 与其单测删除（已无生产调用，避免死代码）。

### 4. 缓存版本

`SystemApplicationIndexCache.version` 8 → 9（新增 `displayName` 字段 + 名称解析规则变化）。

## Files to modify

- `Sources/LeapCore/SystemApplication.swift`
  - `SystemApplicationDescriptor`：新增 `public let displayName: String?`。
  - `descriptor(for:)`：名称候选过滤空白；计算 `name` 与 `displayName`。
  - `localizedNames(in:)`：拆成 preferred / others，新增语言主码匹配辅助方法。
  - 删除 `duplicatedBundleIDs(in:)`；`version` 8 → 9。
- `Sources/Leap/LauncherModel.swift`：`title` → `application.displayName ?? application.name`；`subtitle` → `String?`（应用为 `nil`）。
- `Sources/Leap/LauncherView.swift`：删除 `duplicatedBundleIDs` 计算与 `subtitle(duplicatedBundleIDs:)` 调用。
- `Tests/LeapTests/LauncherShellTests.swift`
  - 新增：只含 `en.lproj` 的包（模拟 Xcode）→ `displayName == 包名`、`name == CFBundleName`、`matchRank(for: "xcode") == 0`。
  - 新增：含 `zh-Hans.lproj` 名称的包 → `displayName == nil`、`name == 中文名`。
  - 新增：`CFBundleDisplayName` 为空字符串且无 lproj（模拟 Copilot）→ `name == CFBundleName`、标题非空。
  - 新增：`CFBundleName` 短名 + `zh_CN.lproj` 无名称键（模拟 VS Code）→ `displayName == 包名`、`name == 短名`、`matchRank(for: "code") == 0`。
  - 更新：删除 `duplicatedBundleIDs` 用例；原副标题断言改为 `nil`。
- `Tests/LeapTests/SearchTextIndexTests.swift`：`displayName` 有默认值，构造调用不需改。

## Reuse

- `LocalizedNames` 相关读取已集中在 `localizedNames(in:)`、`propertyListDictionary(at:)`，只改返回值形态，不新增解析逻辑。
- `(path as NSString).deletingPathExtension` 的写法沿用 `LauncherItem.subtitle` 原实现。
- `SearchMatchRank` / `matchRank` 完全不动：显示名不参与检索。

## Steps

- [x] `SystemApplicationDescriptor` 增加 `displayName`，缓存版本 8 → 9。
- [x] `localizedNames(in:)` 拆 preferred / others，并新增语言主码匹配。
- [x] `descriptor(for:)` 名称候选过滤空白，计算 `name` 与 `displayName`。
- [x] 删除 `duplicatedBundleIDs(in:)`；`LauncherItem` 的 `title` / `subtitle` 改造；清理 View 传参。
- [x] 补/改 LeapTests 用例（上述 5 组）。
- [x] `xcodebuild test -only-testing:LeapTests`、`xcodebuild build`、`swiftlint` 通过。

## Verification

1. `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests` 全绿；`swiftlint lint Sources Tests` 无新增。
2. 手动：启动新构建（缓存版本 9 自动重建索引），搜索 `xcode` → 两行标题 `Xcode-27.2.0` / `Xcode-26.6.0`，无副标题；搜索 `code` → `Visual Studio Code` 在第一屏且无副标题；搜索 `copilot` → `Copilot for Xcode` 标题不再空白。
3. 回归：`cd` → 词典第一；`wx` → 微信第一且无预览；`jqb`、`vsc` 检索正常。
4. 视觉确认后按 AGENTS.md 流程提交，并继续此前被打断的发版（1.1.1 / build 13 → 1.1.2 / build 14）。
