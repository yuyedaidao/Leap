import AppKit
import CoreGraphics
import YQLogger
import SwiftUI

@MainActor
final class LauncherPanelController {
    private static let logger = YQLogger(label: "com.padding.leap/launcher-panel")
    private static let contentWidth: CGFloat = 800
    // 搜索栏高度 70 加上上下各 24 的内边距，避免首帧布局后再调整窗口高度。
    private static let initialContentHeight: CGFloat = 118
    private static let verticalPositionFromTop: CGFloat = 1 / 3

    private let clock = ContinuousClock()
    private let model: LauncherModel
    private var panel: LauncherPanel?

    init(model: LauncherModel) {
        self.model = model
        model.applicationDidLaunch = { [weak self] in self?.hideAfterApplicationLaunch() }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    @discardableResult
    func present(
        on targetDisplayID: CGDirectDisplayID? = nil,
        fallbackLocation: NSPoint? = nil
    ) -> Duration {
        let start = clock.now
        let panel = panel ?? createPanel()
        self.panel = panel

        model.prepareForPresentation()
        Self.positionForPresentation(
            panel,
            targetDisplayID: targetDisplayID,
            fallbackLocation: fallbackLocation ?? NSEvent.mouseLocation
        )
        // 非激活面板可接收键盘输入而不激活 Leap，避免系统按旧窗口归属切换 Space。
        panel.makeKeyAndOrderFront(nil)
        model.requestSearchFocus()
        let elapsed = start.duration(to: clock.now)
        Self.logger.debug("已显示 Leap 搜索面板，耗时：\(String(describing: elapsed))。")
        return elapsed
    }

    func meetsHotWakeBudget(iterations: Int = 20, budget: Duration = .milliseconds(200)) -> Bool {
        guard iterations > 0 else {
            return false
        }
        return (0 ..< iterations).allSatisfy { _ in present() < budget }
    }

    private func hideAfterApplicationLaunch() {
        // 仅收起启动器；隐藏整个应用会在下次激活时恢复旧 Space 中的设置窗口。
        panel?.orderOut(nil)
    }

    private func createPanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.initialContentHeight
            ),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        // 启动器应跟随当前 Mission Control 桌面，而非永久附着在首次创建时的空间。
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("com.padding.leap.launcher")
        panel.contentView = LauncherHostingView(
            rootView: LauncherView(model: model) { [weak panel] height in
                guard let panel else {
                    return
                }
                Self.resize(panel, toContentHeight: height)
            } hideForSettings: { [weak panel] in
                panel?.orderOut(nil)
            }
        )
        return panel
    }

    private static func positionForPresentation(
        _ panel: NSWindow,
        targetDisplayID: CGDirectDisplayID?,
        fallbackLocation: NSPoint
    ) {
        let targetScreen = targetDisplayID.flatMap { displayID in
            NSScreen.screens.first { $0.leapDisplayID == displayID }
        }
        let fallbackScreen = NSScreen.leapScreen(containing: fallbackLocation)
        let screen = targetScreen
            ?? fallbackScreen
            ?? panel.screen
            ?? NSScreen.main
        guard let screen else {
            logger.error("无法确定启动器应显示的屏幕。")
            return
        }
        let source = targetScreen != nil ? "前台窗口" : fallbackScreen != nil ? "鼠标" : "现有面板或主屏"
        let availableScreens = NSScreen.screens.map {
            "ID=\(String(describing: $0.leapDisplayID))，名称=\($0.localizedName)，范围=\(String(describing: $0.frame))"
        }.joined(separator: "；")
        logger.debug(
            "启动器屏幕定位：来源=\(source)，目标 ID=\(String(describing: targetDisplayID))，"
                + "鼠标=\(String(describing: fallbackLocation))，选中 ID=\(String(describing: screen.leapDisplayID))，"
                + "可用屏幕=[\(availableScreens)]。"
        )

        let visibleFrame = screen.visibleFrame
        let targetCenter = NSPoint(
            x: visibleFrame.midX,
            y: visibleFrame.maxY - visibleFrame.height * verticalPositionFromTop
        )
        panel.setFrameOrigin(
            NSPoint(
                x: round(targetCenter.x - panel.frame.width / 2),
                y: round(targetCenter.y - panel.frame.height / 2)
            )
        )
    }

    private static func resize(_ panel: NSWindow, toContentHeight height: CGFloat) {
        guard height.isFinite, height > 0 else {
            logger.error("忽略无效的启动器内容高度：\(height)。")
            return
        }

        // fullSizeContentView 让 SwiftUI 内容与窗口 frame 等高，直接采用测量值可避免标题栏高度被重复累加。
        let targetSize = NSSize(width: contentWidth, height: ceil(height))
        guard abs(panel.frame.height - targetSize.height) >= 1 else {
            return
        }

        var targetFrame = panel.frame
        // AppKit 坐标原点位于左下角，因此固定 maxY 即可让窗口只向下伸展。
        targetFrame.origin.y = panel.frame.maxY - targetSize.height
        targetFrame.size = targetSize
        panel.setFrame(targetFrame, display: true, animate: false)
    }
}

private final class LauncherHostingView: NSHostingView<LauncherView> {
    // fullSizeContentView 让 SwiftUI 内容与窗口 frame 等高，标题栏不应再作为安全区参与布局：
    // 否则 SwiftUI 会把标题栏高度追加到窗口高度上，在材质背景下方留出一条空白。
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Escape 只隐藏常驻面板，避免结束应用或破坏下一次快捷键唤起。
        orderOut(sender)
    }

    override func resignKey() {
        super.resignKey()
        // 非激活面板不会触发应用的失活回调，改由失去键盘焦点时收起。
        if isVisible {
            orderOut(nil)
        }
    }
}
