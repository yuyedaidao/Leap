# 启动器搜索：非汉字脚本转写噪声 + 同 Bundle ID 多份应用

## Context

用户报告两个问题：

1. 输入 `WX`，第一项是「预览」，第二项才是「微信」。
2. 装了两份 Xcode（`Xcode` 与 `Xcode-27.2`），输入 `Xcode` 只显示一个。

用用户机器上的真实索引（`~/Library/Application Support/Leap/application-index-v1.json`，243 个应用）复现：

```
rank=5  预览  [com.apple.Preview]  matched:`แสดงตัวอย่าง`   ← 泰语别名
rank=6  微信  [com.tencent.xinWeChat]  matched:`微信`
rank=7  无线诊断  [com.apple.wifi.diagnostics]  matched:`无线诊断`
```

**问题 1 有两个独立缺陷，缺一都还会复现或留残影**：

- **缺陷 A（等级表：包含高于完全匹配）**：`SearchMatchRank` 的当前顺序是 `pinyinExact(3) < pinyinPrefix(4) < pinyinContains(5) < initialsExact(6)`。「拼音包含」排在「全名首字母完全匹配」之前，语义上讲不通：`wx` 是「微信」两个字的**完整**首字母，理应是强信号，却输给任意一个包含 `wx` 的拼音子串。
- **缺陷 B（转写噪声）**：`SearchTextIndex` 对**任何**文字都跑 `.toLatin` 转写并当成「拼音/首字母」索引。泰语 `แสดงตัวอย่าง` 转写为 `sædngtawxyang`，含 `wx`，命中 `pinyinContains`（等级 5）；`微信` 是 `initialsExact`（等级 6），于是预览在前。非汉字、非拉丁脚本的罗马化对任何查询都无意义——没有人会用 `wx` 指代泰语名。

**问题 2 根因**：`SystemApplicationScanner.scan()` 以 `bundleIdentifier ?? path` 为键去重，同 Bundle ID 只留第一份；Xcode 多版本 Bundle ID 都是 `com.apple.dt.Xcode`。

> 已与用户确认：磁盘上现只余 `/Applications/Xcode-27.2.0.app`，另一份已删除；「只显示一个」发生在两份共存时。

## Approach

### 1. 等级表：完全匹配一律高于包含（修缺陷 A）

`SearchMatchRank` 调成：

| 新等级 | 匹配形态 | 例子（名字 `微信` / `剪切板`） |
| --- | --- | --- |
| 0 | textExact | `微信` |
| 1 | textPrefix | `微` |
| 2 | textContains | `信` |
| 3 | **initialsExact** | `wx`、`jqb`（← 从 6 提到 3） |
| 4 | pinyinExact | `weixin`、`jianqieban` |
| 5 | initialsPrefix | `w`、`jq` |
| 6 | pinyinPrefix | `wei`、`jianqie` |
| 7 | pinyinContains | `eixi`、`qieban` |
| 8 | mixed | `weix` / `wxin` 混拼 |
| 9–11 | identifier* | Bundle ID |
| 12 | content | 插件内容规则 |

即 `enum` 里把 `initialsExact` 移到 `pinyinExact` 之前（`textExact, textPrefix, textContains, initialsExact, pinyinExact, initialsPrefix, pinyinPrefix, pinyinContains, mixed, identifierExact, identifierPrefix, identifierContains, content`），`matchRank` 的查询顺序不变、`rank(...)` 实现不变，只有等级常量变了。

用户实际索引 + 已实测的新顺序：

```
[wx]   微信(3), 无线诊断(5), 预览(7)
[qywx] 企业微信(3)
[tx]   文本编辑(3), 图像捕捉(5), 提醒事项(5), 联系人(5), 腾讯会议(5)
[jsq]  计算器(3)
```

> 「包含」仍然保留在表里，只是不再压过同级或更高级的「完全匹配」：`textContains` 依旧强于 `initialsExact`，因为它是名字里的真实子串；被纠正的是**拼音/首字母内部**的「包含 vs 完全」倒挂。

### 2. 非汉字、非拉丁脚本不再进拼音/首字母索引（修缺陷 B）

`SearchTextIndex.init` 里 token 参与拼音/首字母索引的条件收紧为：**汉字**（走原有整段转写，保留多音字上下文）或 **ASCII**（拉丁字母/数字，`diacriticInsensitive` + `widthInsensitive` 折叠后已是 ASCII）。泰、俄、希腊、希伯来、阿拉伯、假名、谚文等脚本的 token 只保留在 `normalized` 里做字面匹配，不再生成 `pinyin` / `initials`。

改后（配合第 1 节的新等级，已在真实数据上跑过）`SearchTextIndex("แสดงตัวอย่าง").matchRank(for: "wx") == nil`，「预览」只剩中文名 `预览` + `Preview` 参与检索，`wx` 的结果里不再出现「预览」：`微信(3) > 无线诊断(5)`。而 `แสดงตัวอย่าง` 仍可被泰语原文精确命中（等级 0）。

- 顺带覆盖「系统语言是泰语」的场景：泰语名进首选组也不会再因 `wx` 误命中。
- `SystemApplicationIndexCache.version` 7 → 8：缓存里存的是旧算法算出的 `pinyin`/`initials`，必须失效重扫。

### 3. 同 Bundle ID 多份应用全部保留（问题 2）

`scan()` 去重语义改为分层：

- **跨 root**：仍按 Bundle ID 去重，靠前的 root 优先（用户目录 > `/Applications` > 系统），保留「用户副本覆盖全局副本」的既有行为与测试。
- **同一 root 内**：同 Bundle ID 的不同路径全部保留（Xcode 多版本）；只按解析后的真实路径去重（同一 root 内可见符号链接与其目标不会产出两行）。

```swift
var result: [SystemApplicationDescriptor] = []
var claimedIDs: Set<String> = []          // 已被更靠前 root 提供的 Bundle ID
for root in roots {
    var rootIDs: Set<String> = []
    var rootPaths: Set<String> = []
    for application in applications(in: root, fileManager: fileManager) {
        let key = application.bundleIdentifier ?? application.path
        guard !claimedIDs.contains(key), rootPaths.insert(application.path).inserted else { continue }
        rootIDs.insert(key)
        result.append(application)
    }
    claimedIDs.formUnion(rootIDs)
}
```

### 4. 多份应用必须能被选中、能区分（审核阻断项）

`SystemApplicationDescriptor.id` 目前是 `bundleIdentifier ?? path`。两份 Xcode 会得到**相同的 `LauncherItem.id`**，而 `NativeResultList` 用 `ForEach(..., id: \.element.id)` + 每行 `.id(item.id)`，`rowHeights` / `ScrollViewReader.scrollTo` / `selectedSearchResultID` 全按 id 索引 —— 重复 id 会让第二份 Xcode 无法渲染、无法选中、无法启动。仅加副标题不够。

- `id` 改为 `path`（已经是标准化 + 解析符号链接后的路径，天然唯一；`historyKey` 本来就是它）。
- `accessibilityID` 保持 `launcher.application.` + `bundleIdentifier ?? path`，避免改动 `Tests/LeapUITests/LeapUITests.swift:42` 现有的 `launcher.application.com.apple.calculator` 断言。
- 副标题：**仅当结果里同一 Bundle ID 出现多份**时追加包文件名（`应用 · com.apple.dt.Xcode · Xcode-27.2.0`，用 `deletingPathExtension()` 去掉 `.app`）。不做全局追加：243 个应用里 114 个（`微信` / `WeChat.app` 这类）会被加上噪音。

## Files to modify

- `Sources/LeapCore/SearchTextIndex.swift`：
  - `SearchMatchRank` 顺序调整（`initialsExact` 提到 `pinyinExact` 之前，见第 1 节）；
  - `init` 里拼音/首字母索引只收汉字与 ASCII token（非拉丁脚本只保留 `normalized` 字面匹配）。
- `Sources/LeapCore/SystemApplication.swift`：
  - `SystemApplicationDescriptor.id` → `path`；
  - 新增 `public static func duplicatedBundleIDs(in:) -> Set<String>`（纯函数，供副标题消歧）；
  - `scan()` 去重改为跨 root 按 Bundle ID、root 内按解析路径；
  - `SystemApplicationIndexCache.version` 7 → 8（拼音算法变了，旧快照必须失效）。
- `Sources/Leap/LauncherModel.swift`：`LauncherItem.subtitle` → `subtitle(duplicatedBundleIDs:)`（`application.id` 变化后 `LauncherItem.id`、`accessibilityID` 一并核对）。
- `Sources/Leap/LauncherView.swift`：`LauncherSearchResults` 用当前结果集的重复 Bundle ID 集合传给副标题。
- `Tests/LeapTests/SearchTextIndexTests.swift`：
  - `ordering()` 的断言随新等级更新（同组查询的期望值从 `0...8` 变为 `[0,1,2,4,6,7,3,5,8]`，并补「`initialsExact` 必须高于任何 `pinyinContains`」）；
  - 新增「非汉字、非拉丁脚本不产生拼音/首字母匹配」（泰语名 → `wx` 无匹配、泰语原文 → 等级 0）；
  - 缓存版本用例补 `7`。
- `Tests/LeapTests/LauncherShellTests.swift`：
  - `systemApplicationIndexSearchAndCache`：补「同 root 两份同 Bundle ID 都保留」「跨 root 仍取靠前 root」；
  - 新增「同 root 内可见符号链接与目标 → 一行」；
  - 新增 `duplicatedBundleIDs(in:)` 用例（无重复 / 有重复 / 无 Bundle ID 不计入）；
  - 扫描器层面的中文系统优先级用例：`预览`（zh 名 + 泰语 loctable 名）不再命中 `wx`。

## Reuse

- 复用 `SearchTextIndex.rank(...)` / `matchesMixed` / `identifierRank`：匹配算法一行不改，只改等级常量与建索引的字符集条件。
- 复用 `SystemApplicationScanner.descriptor(for:)`、`localizedNames(in:)` 与测试辅助 `makeApplication` / `makeBundle`（已支持多语言 `localizedTable` 与 `preferredLanguages` 注入）。
- 复用 `NativeResultRow(title:subtitle:...)`，只换副标题来源。

## Steps

- [x] `SearchMatchRank` 顺序调整：`textExact, textPrefix, textContains, initialsExact, pinyinExact, initialsPrefix, pinyinPrefix, pinyinContains, mixed, identifier*, content`。
- [x] `SearchTextIndex.init`：拼音/首字母只收汉字与 ASCII token（非汉字非拉丁脚本仅字面匹配）。
- [x] 更新 `SearchTextIndexTests.ordering()` 与新增用例（见上）。
- [x] `SystemApplicationIndexCache.version` 7 → 8。
- [x] `SystemApplicationDescriptor.id` → `path`；核对 `LauncherItem.id` / `accessibilityID` / 选中与滚动路径。
- [x] `scan()` 分层去重（跨 root 按 Bundle ID、root 内按路径）。
- [x] `SystemApplicationDescriptor.duplicatedBundleIDs(in:)` + `LauncherItem.subtitle(duplicatedBundleIDs:)` + 视图传入重复集合。
- [x] 更新/新增上述单测；`swiftlint` 通过。
- [x] `xcodebuild test -only-testing:LeapTests` 通过。
- [x] 起 App 手动验证（设置 → 重建应用索引，让新缓存版本生效）。

## Verification

1. `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`
2. `swiftlint`
3. 手动（重建应用索引后）：
   - `wx` → 首项「微信」；`预览` 不再出现在 `wx` 结果里。
   - `wechat` / `jianqie` 之类英文与拼音查询仍能命中「微信」「剪切板」。
   - `jqb` / `vsc` / `hdjsq` 这类首字母查询仍排在同名拼音子串之前（新等级的直接体现）。
   - 造两份同 Bundle ID 的应用（或跑单测）→ 两条都在、各自可选中、副标题能区分版本（`…· Xcode-27.2.0`）。
   - `qywx` / `tx` / `jsq` 等常用首字母查询顺序无意外变化。

## 审核反馈处理

**计划审核（用户）**：「拼音包含比首字母完全匹配等级高，包含比完全匹配高合理吗？」——不合理，已改为**完全匹配高于包含**（第 1 节），`initialsExact` 从 6 提到 3；`textContains` 仍高于 `initialsExact`（它是名字里的真实子串，不是转写产物）。这同时意味着即使不做第 2 节的转写修复，`wx` 的排序也已正确（微信 3 < 预览 7），两项一起做是为了让「预览」彻底不再出现在 `wx` 结果里。

**deepseek-reviewer（独立审核）**：

- 阻断 1（同 Bundle ID 的 `id` 冲突导致无法渲染/选中）→ 已改为 `id = path`，并核对 UI 测试的 accessibility 标识。
- 阻断 2（`LauncherItem` 在 `LeapTests` 不可见）→ 消歧所需的重复判定下沉到 `LeapCore`（`duplicatedBundleIDs(in:)`）并在 `LeapTests` 覆盖；副标题字符串本身留 App 层，靠手动验证。
- 中 3（Codable 形态）→ 本次不改 `SystemApplicationDescriptor` 结构，只升缓存版本。
- 中 4（`alternateNames` 语义收窄）→ 不适用：不做语言分组，`alternateNames` 语义与生成方式不变。
- 轻微 5（`otherLanguageOffset` 与 `content` 排序）→ 不适用：不做语言分组。
- 轻微 6（`.app` 后缀）→ 明确用 `deletingPathExtension()`。
- 轻微 7（首选组边界影响显示名）→ 不适用：不拆分名称组。

## 未纳入本次改动

- **语言分组 + 其它语言别名兜底偏移**（曾被提议的「系统语言优先」实现）：等级表修正 + 转写修复后，`wx` 已不会再命中「预览」，按语言分组要多付一个 Codable 字段、缓存结构与 `launcher shell` 断言改动，收益为零。若后续真出现「拉丁字母别名压过系统语言名称」的实例，再按分组实现。
- **彻底丢弃非首选语言别名**：保留用其它语言原名搜索应用的能力（泰语原文仍可精确命中）。
