import AppKit
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
    private var panel: NSWindow?

    init(model: LauncherModel) {
        self.model = model
        model.applicationDidLaunch = { [weak self] in self?.hideAfterApplicationLaunch() }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    @discardableResult
    func present(at triggerLocation: NSPoint? = nil) -> Duration {
        let start = clock.now
        let panel = panel ?? createPanel()
        self.panel = panel

        model.prepareForPresentation()
        Self.positionForPresentation(panel, triggerLocation: triggerLocation ?? NSEvent.mouseLocation)
        NSApp.activate(ignoringOtherApps: true)

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
        panel?.orderOut(nil)
        NSApp.hide(nil)
    }

    private func createPanel() -> NSWindow {
        let panel = LauncherWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.initialContentHeight
            ),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // 启动器失去应用焦点时立即收起，避免继续悬浮在用户当前操作的窗口上方。
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

    private static func positionForPresentation(_ panel: NSWindow, triggerLocation: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(triggerLocation) }
            ?? panel.screen
            ?? NSScreen.main
        guard let screen else {
            logger.error("无法确定启动器应显示的屏幕。")
            return
        }
        logger.debug("将在 \(screen.localizedName) 显示启动器，触发坐标：\(String(describing: triggerLocation))。")

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

private final class LauncherWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        // Escape 只隐藏常驻面板，避免结束应用或破坏下一次快捷键唤起。
        orderOut(sender)
    }
}
