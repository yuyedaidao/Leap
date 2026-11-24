# 去掉启动器四角残留的半透明底

## Context

上一轮把 `panel.hasShadow = false` 之后，四角那条「奇怪的弧线」（系统按窗口圆角画的阴影）消失了。但四角仍然残留一圈**浅灰色雾带**，用户原话：「现在能看到一点模糊的背景，需要处理掉，不能有这个背景」。

对用户截图（`828×488`，2x 裁剪，窗口左上角在 (38,26) 像素）逐像素测得：

| 事实 | 数据 |
| --- | --- |
| 玻璃弧 | 圆心距离窗口角 58px（=29pt），与 `RoundedRectangle(cornerRadius: 30)`（circular）一致 |
| 残留雾带位置 | 在玻璃弧**外侧**，半径 58→68px（约 5pt 宽），沿弧线分布 |
| 雾带颜色 | 中性灰 (229,229,229)…(238,238,238)，即约 4~8% 黑，**不是**模糊后的桌面内容（背景区域是纯 249 均色，无内容可模糊） |
| 雾带外沿 | 在 249→238 之间**一像素硬切**，硬切位置正好是窗口自身的矩形边 / 窗口圆角弧（≈28px=14pt） |
| 直边 | 完全没有雾带：左边缘 `x=37 → 249`、`x=38 → 102`，上边缘 `y=25 → 249`、`y=26 → 155`，干净 |

结论：玻璃只画到 30pt 圆弧，而**窗口矩形 + 系统窗口圆角把一块半透明图层裁出了硬边**——也就是有一层玻璃自带的外扩阴影/色层溢出到形状之外，在直边被窗口边界整块裁掉所以看不见，只有在四角「窗口圆角比玻璃圆角更贴角」的那块缝隙里露出来。硬切边界 + 平坦灰值说明它是被裁剪的图层，而不是柔和的模糊。

`panel.hasShadow = false` 只关掉了 **NSWindow 系统阴影**，关不掉 SwiftUI `glassEffect` 自己带的外扩图层。

## Approach

把启动器内容**按玻璃形状本身裁掉**，让任何溢出形状之外的像素都没有机会画出来。

- `Sources/Leap/LauncherView.swift` 玻璃层之后加 `clipShape`，形状与 `glassEffect` 传入的 `RoundedRectangle(cornerRadius: 30)` 完全一致（同一个值，抽成一个常量避免两处漂移）。
- 范围限定在启动器，不动设置窗口。

不做的事：不改玻璃形态、不改圆角半径、不加阴影、不动 BorderBeam、不改 AppKit 侧任何代码。

## Files to modify

- `Sources/Leap/LauncherView.swift`（`.glassEffect(...)` 一处，第 68 行附近）

## Reuse

- 不新增文件、不新增类型；圆角值就地抽成 `LauncherView` 的私有常量，沿用 `LauncherSearchHeader` 里 `let defaultHeight: CGFloat = 60` 这类就地常量风格。

## Steps

- [x] 1. 在 `LauncherView` 里把 30 抽成 `private let cornerRadius: CGFloat = 30`，`glassEffect` 与新的 `clipShape` 共用
- [x] 2. 在 `.glassEffect(...)` 之后加 `.clipShape(RoundedRectangle(cornerRadius: cornerRadius))`，紧随其后保留现有 `.ignoresSafeArea()`
- [x] 3. 构建 + lint
- [x] 4. 让用户提供深色模式下四角截图复核（若雾带仍在，停下来把新证据报给你再定下一步，不自行改用 AppKit 方案）

## Verification

- `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- `swiftlint lint --quiet Sources/Leap/LauncherView.swift Sources/Leap/LauncherPanelController.swift`
- 目视：深色模式下四角应只剩玻璃自身的边界，弧外全部透桌面，不再有灰雾。
  - **注意**：我这边的自动截图通道已被 macOS 自动化授权弹窗阻断（多次尝试均 block，不再重试），四角复核需要用户截图或自己看一眼。
- 附带的量化判定（用户给截图后我可以跑）：沿角点 45° 方向采样，玻璃弧外应直接等于桌面色，不应再出现 200–246 之间的平台段。

## 风险

- 裁剪后四角边缘会从「2~3px 柔化」变为「硬切」，与外圈彻底贴合；这是消除残留的必然代价，视觉上通常更干净。
- 若雾带其实由窗口 frame view 绘制，SwiftUI 的 `clipShape` 会无效；那就不是你这次选的方案能解决的，我会带证据停下来问你。
