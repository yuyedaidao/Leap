# 修复：Safari 搜索不到（隐藏标志的 .app 符号链接被跳过）

## Context

用户报告本机 Safari 在 Leap 中搜不到。实测根因（非 bundle 解析问题，纯枚举阶段丢失）：

- `/Applications/Safari.app` 是符号链接：`Safari.app -> ../System/Cryptexes/App/System/Applications/Safari.app`
  （解析后落到 `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app`）。
- 该符号链接带有 `hidden` 文件标志（`ls -lO` 输出 `lrwxr-xr-x@ 1 root wheel restricted,hidden 54 Safari.app -> ...`）。
- `SystemApplicationScanner.applications(in:)` 用 `FileManager.enumerator(options: [.skipsHiddenFiles, .skipsPackageDescendants])`，
  `.skipsHiddenFiles` 把带 UF_HIDDEN 的 `Safari.app` 在**产出阶段**就过滤掉了，后面的 `resolvedApplicationURL` / `descriptor`
  根本没有机会运行。

对照实验（本机，swiftc 脚本，只读）：

| 枚举方式 | `/Applications` 顶层产出 | 含 Safari.app |
| --- | --- | --- |
| `[.skipsHiddenFiles, .skipsPackageDescendants]`（现状） | 156 | 否（差异恰为 `.DS_Store`、`.localized`、`Safari.app`） |
| 去掉 `.skipsHiddenFiles` | 159 | 是 |
| 完整扫描（替代方案，见下方） | 165 个描述符 | 是，耗时 6ms（与原实现同量级） |

`Bundle(url: /Applications/Safari.app)` 能正常取到 `com.apple.Safari` / `CFBundlePackageType=APPL` / 可执行文件存在，
`URL(resolvingAliasFileAt:)` 也能解析；`/System/Applications`（65）、`/System/Library/CoreServices/Applications`（12）、
`~/Applications`（9）都无 hidden 标志、结果不变。即：问题只出在 `skipsHiddenFiles`。

预期结果：Safari（以及任何以隐藏符号链接形式挂载的系统应用）能被索引并可搜索。

## Approach

把“隐藏”判定从 `FileManager.enumerator`（产出即丢弃，无法补救）移到遍历循环里，并且只对**解析后的真实 .app** 放行：

```swift
guard let enumerator = fileManager.enumerator(
    at: root,
    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
    options: [.skipsPackageDescendants]          // 去掉 .skipsHiddenFiles
) else { return [] }

for case let sourceURL as URL in enumerator {
    let url = resolvedApplicationURL(for: sourceURL)
    guard url.pathExtension == "app" else {
        // 隐藏的普通目录/文件才跳过其后代；隐藏 .app 需要索引。
        if isHidden(sourceURL) { enumerator.skipDescendants() }
        continue
    }
    enumerator.skipDescendants()
    ...
}
```

- 保留“不进隐藏目录 → 少扫大量噪声、行为与之前一致”，同时放过 hidden 的 `.app`（`resolvedApplicationURL` 解析别名后判定）。
- `isHidden` 用 `url.resourceValues(forKeys: [.isHiddenKey]).isHidden == true`，与已有 `includingPropertiesForKeys` 对齐。
- 缓存版本 `SystemApplicationIndexCache.version` 从 `5` 提到 `6`：老用户缓存里没有 Safari，不失效就不会生效（启动时 `load`
  版本不符即返回 nil 触发重扫）。

不做的事：不新增 `/System/Cryptexes/App/System/Applications` 之类硬编码 root（已能通过别名解析覆盖，且跨机器不稳定）；
不改 `defaultRoots`；不改 FSEvents 监听与 UI 侧逻辑。

## Files to modify

- `Sources/LeapCore/SystemApplication.swift`
  - `SystemApplicationScanner.applications(in:fileManager:)`（约 92–113 行）：枚举选项、hidden 判定、循环体。
  - `SystemApplicationIndexCache.version`（212 行）：`5` → `6`。
- `Tests/LeapTests/LauncherShellTests.swift`
  - 缓存 version 失效测试的 `for version in [2, 3, 4]` → `[2, 3, 4, 5]`。
  - `makeApplication` 增加 `isSymbolicLink: Bool = false`：先建真实 .app，再在目标 root 建一个指向它的符号链接，
    并给链接打上 `hidden` 属性（`setAttributes([.posixPermissions:...])` 不行，需 `chflags hidden`——测试里用
    `/usr/bin/chflags` 或 `FileManager.setAttributes` 无对应键，故用一次 `Process` 调 `/usr/bin/chflags hidden <path>`，
    可参考仓库中已有的进程调用写法；若拒绝引入，则该测试用 `@Test(.disabled("需要 chflags"))` 标注并说明）。
  - 新增测试「隐藏的符号链接 .app 仍会被索引」：断言 `applications.map(\.bundleIdentifier)` 含该 app、
    `matchRank(for:)` 可命中；并断言隐藏的普通目录不贡献结果（回归保护）。

## Reuse

- `resolvedApplicationURL(for:)`（`SystemApplication.swift:114`）：已有的别名解析，hidden 判定要在它之后用返回/原始 URL。
- `descriptor(for:fileManager:)`：无需改动，已是正确的过滤边界。
- 测试复用 `makeTemporaryPluginDirectory()` 与 `makeApplication(...)`。
- 排查时写的只读探针脚本属于一次性验证，不入库。

## Steps

- [x] 改 `applications(in:)`：去掉 `.skipsHiddenFiles`，加 hidden 判定与 `skipDescendants` 规则（含中文注释说明为什么不能依赖 `.skipsHiddenFiles`）。
- [x] 缓存版本 `5` → `6`。
- [x] 更新缓存失效测试的旧版本列表为 `[2, 3, 4, 5]`。
- [x] `makeApplication` 支持生成隐藏符号链接的 .app，新增回归测试。
- [x] `swiftlint` + `xcodebuild test ... -only-testing:LeapTests`。

## Verification

1. 单测：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`（新测试覆盖 hidden 链接与隐藏目录两种情形）。
2. 真机：`xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'` 后运行 Leap，
   搜 `safari` / `llq`（浏览器拼音首字母按现有规则）/ `浏览器`，能看到 Safari 并可启动。
3. 回归：确认 `.DS_Store`、`.localized` 之类隐藏项未进入列表，`/Applications` 其余应用数量不减少，
   启动扫描耗时仍在毫秒级。
4. 老缓存用户升级后无需手动“重建索引”即可看到 Safari（版本号失效生效）。
