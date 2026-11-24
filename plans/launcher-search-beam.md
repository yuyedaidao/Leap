# 启动器输入框光带动效（集成 BorderBeam）

## Context

启动器面板刚打开、输入框还空着时，界面是静默的：一个胶囊搜索条 + 最近记录列表。用户希望这时有一条光被动效提示「这里可以输入」，输入开始后立即消失，不干扰正常使用。

依赖已由用户手动接入（`border-beam-ios`，MIT，SwiftUI + 单个 Metal shader 的 `colorEffect`，macOS 14+）：

- `Tuist/Package.swift:22` — `.package(url: "https://github.com/ismnoiet/border-beam-ios.git", branch: "main")`
- `Tuist/Package.swift:12` — `PackageSettings` 里给 `BorderBeam` 设 `MACOSX_DEPLOYMENT_TARGET: 26.0`
- `Project.swift:52` — `Leap` app target 加 `.external(name: "BorderBeam")`
- `Tuist/Package.resolved` 锁定 `a11d1b938b1cc8efad02e942f7590a0156bbd7da`
- `Leap.xcodeproj` / `Leap.xcworkspace` 已重新生成，workspace 里能看到 `BorderBeam` 包

所以本计划只剩一件事：**在 `LauncherSearchHeader` 上挂触发逻辑**。

### 当前构建状态（已验证）

Metal 工具链已安装、`default.metallib` 已生成、bundle 已嵌入 app，无需再动依赖侧任何东西：

```
xcrun -sdk macosx metal --version  → Apple metal version 32023.922
xcodebuild build …                → ** BUILD SUCCEEDED **
Leap.app/Contents/Resources/BorderBeam_BorderBeam.bundle/Contents/Resources/default.metallib  ✓
```

## Approach

### 依赖侧已就绪，不用再动

Metal 工具链已由用户安装，`xcodebuild` 当前**构建通过**，`BorderBeam_BorderBeam.bundle` 及其 `default.metallib` 已随 `Leap.app` 打包，上游 `BeamBundle.resources` 走 `Bundle.module` 能找到 shader。不需要 `vendor` 源码，也不需要在 `Project.swift` 里补任何资源声明。

### 触发逻辑（唯一的新代码）

不改动任何布局尺寸，只加状态和一层 overlay：

- `LauncherModel` 已有 `focusRequestID`，每次 `requestSearchFocus()` 自增；`present()` → `prepareForPresentation()` 把 `query` 清空 → `requestSearchFocus()`，因此「每次唤起且输入为空」恰好对应 `focusRequestID` 每次自增。
- `LauncherSearchHeader` 加 `@State private var beamActive = false`，在 `.task(id: focusRequestID)` 里判断 `query.isEmpty` 且 `interaction == nil` → 亮起 → `Task.sleep(约 3 秒)`（一圈 2.4s + 0.6s 淡出）→ 置 false。
- `.onChange(of: query)` 里 `query` 首次非空立即置 false，让光带随第一个字符消失。
- 光带贴在现有搜索胶囊外侧：在 `.background(.tertiary.opacity(0.25), in: RoundedRectangle(cornerRadius: defaultHeight / 2, style: .continuous))` 那一层之后加 `.borderBeam(shape: .capsule, active: beamActive, colors: BeamPalette.colorful)`。

### 已定决策（用户确认）

| 决策 | 结论 |
|---|---|
| 依赖接入方式 | 用用户已接好的外部 SPM 包，不 vendor 源码 |
| 触发时机 | 每次唤起面板、且输入为空时播放一次；输入首个字符立即熄灭 |
| 光带形态 | `.large`（彗星沿整圈边框顺时针绕行 + 柔和内发光），`style` 用默认值 |
| 配色 | `BeamPalette.colorful`（库里第一个现成配色） |
| 形状 | `.capsule`，贴合 60pt 胶囊（圆角 30） |
| 播放时长 | 默认 `rotateDuration` 2.4s 一圈 + 库自带 0.6s 淡入淡出 |

## Files to modify

| 文件 | 改动 |
|---|---|
| `Sources/Leap/LauncherView.swift` | `LauncherSearchHeader` 加 `beamActive` 状态、`.task(id: focusRequestID)` 触发、`.onChange(of: query)` 熄灭，胶囊层加 `.borderBeam(...)` |
| `Sources/Leap/LauncherView.swift` | 顶部 `import BorderBeam` |
| `Project.swift` / `Tuist/Package.swift` | 不改（用户已接好） |

## Reuse

- `LauncherModel.focusRequestID` / `requestSearchFocus()`（`Sources/Leap/LauncherModel.swift:543`）：现成的「每次唤起」信号，不加通知也不用时间戳。
- `LauncherModel.prepareForPresentation()`（同文件 `:547`）：唤起时已清空 `query`，「输入为空」天然成立。
- `LauncherSearchHeader` 现有 `defaultHeight = 60` 胶囊背景（`Sources/Leap/LauncherView.swift` 内）：光带贴着它走，无需新容器。
- 上游 `BeamStyle` / `BeamShape` / `BeamPalette` / `BeamTiming` / `.borderBeam` 修饰符：直接用，不自己写动画。

## Steps

- [x] `LauncherView.swift` 加 `import BorderBeam`
- [x] `LauncherSearchHeader` 加 `beamActive`：`.task(id: focusRequestID)` 判断 `query.isEmpty && interaction == nil` → 亮起 → 定时熄灭；`.onChange(of: query)` 首个非空字符立即熄灭
- [x] 胶囊层加 `.borderBeam(shape: .capsule, active: beamActive, colors: BeamPalette.colorful)`
- [x] 构建验证（依赖与 shader 已就绪，只关注新代码）
- [x] 连开面板验证：每次唤起且空输入播放一次，输入立即停止，插件交互/Shell 运行时不出现

## Verification

- 构建：`xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- Lint：`swiftlint lint --quiet Sources/Leap/LauncherView.swift`（新增代码零 error）
- 手动：反复按热键唤起启动器，确认光带每次出现在空输入状态并在约 3 秒后淡出；输入第一个字符立即淡出；`⌘,` 设置、插件交互（输入框被替换）时不出光带
- Reduce Motion：系统开启「减弱动态效果」时 BorderBeam 自动退化为静止光带，确认不闪烁

## Risks

- 上游代码按 Swift 5.9 写，本工程 `SWIFT_VERSION 6.0` + `SWIFT_STRICT_CONCURRENCY: complete`：`BeamClock` 是非 `Sendable` 的 `final class` 被 `@State` 持有，可能出现严格并发诊断。依赖已能编过，若接入后报错，优先在调用处用 `@preconcurrency import BorderBeam` 压制，不改依赖源码。
- 上游只有 `branch: "main"`，无 tag。`Package.resolved` 已锁到 `a11d1b9`，但只要有人 `tuist install` 重新解析就可能漂移；若要长期稳定，后续考虑 fork 或改 `revision:` 锁定（本次不做）。
- 视觉改动，按 AGENTS.md 需用户先确认效果再提交。
