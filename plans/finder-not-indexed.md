# 修复：访达（Finder）搜索不到

## Context

用户报告：Leap 里搜不到「访达」。上一轮（commit `67f961d`）已修好 Safari 的隐藏符号链接问题，本轮是另一类丢包。

本机实测（macOS 26.5 / build 25F71）根因在 `SystemApplicationScanner.descriptor(for:)` 的硬编码包类型闸门：

| 应用 | `CFBundlePackageType` | 现值是否收录 |
| --- | --- | --- |
| `/System/Library/CoreServices/Finder.app` | `FNDR` | ❌ 被 `== "APPL"` 过滤 |
| `/System/Applications/Passwords.app` | `XPC!` | ❌ 同上 |
| 其余 245 个第三方 / 系统应用 | `APPL` | ✅ |

闸门代码（`Sources/LeapCore/SystemApplication.swift:133-145`）：

```swift
info["CFBundlePackageType"] as? String == "APPL",
```

Finder 是 `FNDR`（`com.apple.finder`，`CFBundleExecutable = Finder` 存在且可执行），
`/System/Library/CoreServices/Finder.app` 本身已在 `defaultRoots` 里，所以只差这一个判定。

名称解析已经通了，实测仓库同款 `localizedNames(in:)` 对 Finder.app 返回
`["访达", "访达", …]`（来源 `Contents/Resources/InfoPlist.loctable` 的 `zh_CN.CFBundleDisplayName`），
所以放行后即可用「访达 / finder / fd（拼音首字母）」命中，不需要动检索逻辑。

预期结果：搜「访达」能出现并激活 Finder。

## Approach

**按用户决定，彻底去掉包类型闸门**（不再枚举 `APPL/FNDR/XPC!` 白名单，避免以后又冒出 `FNDR` 之外的第四种类型），
其余判定不动：`LSBackgroundOnly` 仍排除、可执行文件必须存在、路径不以 `.` 开头。

连带影响（已实测）：真实默认 root（`/System/Library/CoreServices/Applications` 子目录 + 显式 Finder.app）内
原本被类型闸门挡住的只有两个：

| 路径 | type | 最终显示名 |
| --- | --- | --- |
| `/System/Library/CoreServices/Finder.app` | `FNDR` | 访达 |
| `/System/Applications/Passwords.app` | `XPC!` | 密码 |

`CoreServicesUIAgent.app` / `ManagedClient.app` / `WiFiAgent.app` / `PassViewer.app` / `liquiddetectiond.app`
虽也不是 `APPL`，但位于 `/System/Library/CoreServices/` 父目录，`defaultRoots` 根本不扫那里，不会因此新增。

`/Applications/Canon Utilities/**/ReadMe(EOS Utility).app` 是文档包（`CFBundlePackageType` 类似 `TEXT`），
按用户决定本轮不处理（只修访达这一类）。

另外两处配套改动：

- `SystemApplicationIndexCache.version` `6` → `7`：老用户快照里没有访达，不失效就不会生效。
- 不按 `LSUIElement` 收紧过滤：现网 `LSUIElement = true` 的第三方应用（Wox、Docker、iShot…）当前可被搜索，
  收紧属于行为回退，与本 bug 无关。

## Files to modify

- `Sources/LeapCore/SystemApplication.swift`
  - `descriptor(for:fileManager:)`：删掉 `CFBundlePackageType == "APPL"` 条件，中文注释说明
    Finder（`FNDR`）、密码（`XPC!`）等系统应用的包类型不是 `APPL`，白名单会一直漏。
  - `SystemApplicationIndexCache.version`：`6` → `7`。
- `Tests/LeapTests/LauncherShellTests.swift`
  - `makeBundle(...)` 增加 `packageType: String? = "APPL"`（`nil` 表示不写该键），供新测试构造 `FNDR` / 缺失类型的包。
  - 缓存失效断言的旧版本列表 `[2, 3, 4, 5]` → `[2, 3, 4, 5, 6]`。
  - 新增测试：同目录放 `FNDR`（Finder 形态，含 `InfoPlist.loctable` 的 `zh_CN.CFBundleDisplayName = 访达`）、
    `XPC!`、以及完全不写 `CFBundlePackageType` 的三个包，断言都被索引且 `matchRank(for: "访达")` / `"finder"` 命中；
    同目录再放一个 `LSBackgroundOnly = true` 的包，断言仍被排除（回归保护）。

## Reuse

- `resolvedApplicationURL(for:)`、`isHidden(_:)`、`localizedNames(in:)`：无需改动，全部复用。
- 测试 helper `makeTemporaryPluginDirectory()`、`makeApplication(...)`、`makeBundle(...)`：扩展一个参数即可。
- `SystemApplicationWatcher`（FSEvents，监听 `scanner.roots`）：无需改动。

## Steps

- [x] `descriptor(for:)` 去掉 `CFBundlePackageType == "APPL"` 判定，加中文注释说明为什么不能用类型白名单。
- [x] `SystemApplicationIndexCache.version` `6` → `7`。
- [x] 测试夹具 `makeBundle` 支持自定义/缺省 `CFBundlePackageType`；旧版本列表补 `6`。
- [x] 新增 `FNDR` / `XPC!` / 无类型 三例索引测试 + `LSBackgroundOnly` 仍被排除的断言。
- [x] `swiftlint` + `xcodebuild test … -only-testing:LeapTests`。

## Verification

1. 单测：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`。
2. 构建并运行：`xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`，
   搜 `访达` / `finder` / `fd` 能看到访达；点回车应激活已在运行的 Finder（不产生第二个 Finder 进程，需人工确认）。
3. 缓存生效：不手动点「重建索引」，升级后直接可见访达（版本号失效生效）。
4. 噪声核查：搜 `密码` 能出 `Passwords`（放宽后的预期，非 bug）；确认 `Applications` 列表可滚动、无重复条目。
