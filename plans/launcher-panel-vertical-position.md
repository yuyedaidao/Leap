# 修复启动器偶尔出现在屏幕上方（落点依赖上一次内容高度）

## Context

用户反馈：启动器**大多数时候**居中在屏幕高度 1/3 处，但**有时候明显偏上**。

代码已能定位到根因（`Sources/Leap/LauncherPanelController.swift`）：

1. `present()`（:81）依次做：`model.prepareForPresentation()` → `positionForPresentation(panel, …)`（:88）→ `makeKeyAndOrderFront`。
2. `positionForPresentation`（:214-232）用**面板当前的 frame.height** 反推原点：

   ```swift
   let targetCenter = NSPoint(x: visibleFrame.midX,
                              y: visibleFrame.maxY - visibleFrame.height * verticalPositionFromTop) // 1/3
   panel.setFrameOrigin(NSPoint(x: … , y: round(targetCenter.y - panel.frame.height / 2)))
   ```

   即「中心落在 1/3」，但中心是用**旧高度**算的 → 高度越高，顶边被推得越高。
3. `resize`（:236-257）在 SwiftUI 报上新高度时**固定 maxY（顶边）只向下缩**：

   ```swift
   targetFrame.origin.y = panel.frame.maxY - targetSize.height
   ```

   所以那次“按旧高度算出来的顶边”会被**原样保留**。

于是：上一次会话停留在长列表 / 插件列表（高度 326、600…）后收起面板，窗口仍是那个高度 → 下次唤起按这个高度定位 → 顶边被顶到屏幕上方 → 首帧布局把高度缩回空态的 214 时，`resize` 只缩下沿，顶边留在高处。

实机证据（录屏时踩到的同款）：`windows.swift` 读到的面板是 `Leap [layer 3] 464,105 800x219`，而正常应为 `464,299 800x214`——105 正是“按 ~600 高度算 1/3 中心”的结果。当时只能在录屏脚本里靠 `settle_panel()` 反复“呼出→读坐标→收起”直到 y 落在 280–305，属于绕开问题。

目标：**无论上次面板多高，唤起时都落在同一位置**；内容变长时仍保持现有行为（顶边不动，向下伸展）。

## Approach

位置语义沿用现状：**面板中心落在可用高度的 1/3 处**（`verticalPositionFromTop = 1/3`），内容变长时顶边不动、向下伸展。本计划只修「用旧高度算中心」这个时序问题，不改观感。

做法：让「按 1/3 居中」发生在**内容尺寸稳定之后**，而不是唤起瞬间：

1. `present()` 仍先用当前高度落位（避免首帧出现在旧位置），随后置位 `awaitsSettle = true`。
2. SwiftUI 的 `contentHeightDidChange` 回调（`LauncherView.swift:76-82`）第一次进来时，若 `awaitsSettle` 为真，则**用这个新高度重新按 1/3 居中**；无论走哪条分支都立刻清掉 `awaitsSettle`（防止高度恰好没变、后续打字时误居中）。
3. 之后的高度变化保持现状：固定 maxY、只向下伸展；`keepWithinScreen`（交互 / 前台 Shell）的向上让位逻辑不变。

几何计算抽到 `LeapCore`（现有 `LauncherListShortcut`、`WindowDisplayResolver` 的同款做法，纯函数可单测）：

- `LauncherPanelGeometry.centeredOrigin(screen:panelSize:verticalFraction:)` → 中心落在 `verticalFraction` 处
- `LauncherPanelGeometry.keepingTopEdge(_ frame:toHeight:clampingTo:bottomInset:)` → 顶边不动、只改高度（含 `keepWithinScreen` 的下限夹取）

`LauncherPanelController` 的 `positionForPresentation` / `resize` 改为调用它们。

顺带：`~/Work/Project/2026/LeapVideo/tools/shoot.sh` 里的 `settle_panel()` 是这毛病的绕行方案，本次不改（它仍能工作），但修好后录屏不再需要重试。

## Files to modify

- `Sources/LeapCore/LauncherPanelGeometry.swift`（新增，纯几何）
- `Sources/Leap/LauncherPanelController.swift`（`present` / `positionForPresentation` / `resize` 及高度回调）
- `Tests/LeapTests/LauncherPanelGeometryTests.swift`（新增，`Swift Testing`，`@testable import LeapCore`）

## Reuse

- 单测风格与目录：`Tests/LeapTests/FrontmostWindowDisplayResolverTests.swift`、`LauncherShellTests.swift`（`import Testing` + `@testable import LeapCore`）
- `Sources/LeapCore/WindowDisplayResolver.swift`：同类的纯逻辑 + 屏幕几何先例
- 高度来源不变：`LauncherView.swift:76-82` 的 `onGeometryChange`；`LauncherPanelController.createPanel()` 里的回调签名只加一个 captured `self`

## Steps

- [x] 新增 `Sources/LeapCore/LauncherPanelGeometry.swift`：`centeredOrigin`、`keepingTopEdge` 两个纯函数（`CGFloat`/`NSRect`，`import CoreGraphics`，与 `WindowDisplayResolver` 保持同样的注释风格）
- [x] `LauncherPanelController`：加 `private var awaitsSettleAfterPresentation = false`；`present()` 在 `makeKeyAndOrderFront` 前置位
- [x] 高度回调：首次进入时清标志，并把 `recenterVertically` 传给 `resize`
- [x] `resize(_:toContentHeight:keepWithinScreen:recenterVertically:)`：居中分支走 `centeredOrigin`，否则走 `keepingTopEdge`
- [x] `positionForPresentation` 改用 `centeredOrigin`（行为不变，只是去重）
- [x] `Tests/LeapTests/LauncherPanelGeometryTests.swift`：① 同一屏幕下高度从 600 变 214，`centeredOrigin` 得到的两条顶边一致（这次 bug 的回归断言）；② `keepingTopEdge` 顶边不变、底部按需夹到 `visibleFrame.minY + 12`；③ 中心确实落在 1/3
- [x] `swiftlint` + 单测 + 手动复现（见下）

## Verification

- 单测：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`
- 构建：`xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- 手动复现（改前必现、改后必须消失）：跑起 App → `⌥Space` 唤起 → 输入 `a` 拉出一长串结果（面板明显变高）→ Esc 收起 → 再 `⌥Space`：面板顶边应与“刚启动时”完全一致
- 交叉验证：用 `~/Work/Project/2026/LeapVideo/tools/windows.swift` 读 `Leap [layer 3]` 的 y 值，长列表收起后重开应稳定在同一 y（此前会在 105 / 299 之间跳）
- 打字变长时面板只向下伸展（不整块上移）：输入 `a` → 再输入 `ap` 观察顶边不动

## 执行记录（实现比计划多修了两处）

计划里的「首次布局回调时重新居中」不够用，实机验证后发现两个额外问题，已按 Risks 里的兜底方案改正：

1. **没有回调可等**：唤起时高度若与上次相同（例如上次也是空态），SwiftUI 的 `onGeometryChange` 根本不触发，标志位留到第一次打字才消费，反而把变长的面板做成了上下对称生长（实测从 285 变成 105）。改为**缓存空态高度** `settledEmptyContentHeight`（查询为空且无交互时由高度回调更新），定位时始终用它做锚点，不再依赖回调时序。
2. **定位被系统夹到屏幕顶端**：旧窗口 580 高时只调 `setFrameOrigin`，算出的原点会被 AppKit 夹到 `visibleFrame.maxY - 580`（顶边贴屏幕顶端），随后的收缩又把这个被夹住的顶边当作基准保留。改为 `setFrame` 一次下发**尺寸 + 原点**（锚点高度），高度先归位再定位。

实机验证（debug 构建 + `LeapVideo/tools/windows.swift` 读 `Leap [layer 3]`）：冷启动 `464,285 800x219` → 输入 `a` 变高 `464,285 800x580`（顶边不动）→ 收起重开 `464,285 800x219`（回到冷启动位置）→ 再输入 `gj` / 再次重开均稳定在 285。

注：实机核对时输入法在微信拼音态，临时用 `TISSelectInputSource` 切到 ABC，验证后已切回。

## Risks

- 首次布局若先报一个中间高度再报最终高度，会在同一 runloop 内居中两次 → 最多一帧的位置跳动；因为面板此刻刚 orderFront，实际不可见。若真出现闪动，兜底方案是“空态高度缓存”（记住上次空态高度作为锚点），改动同样小。
- 若面板已可见时再次 `present()`（插件通知、插件运行回调），行为与现在一致：高度不变则不会触发居中分支。
