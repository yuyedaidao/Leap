import AppKit
import YQLogger
import SwiftUI

@MainActor
final class LauncherPanelController {
    private static let logger = YQLogger(label: "com.padding.leap/launcher-panel")
    private static let contentWidth: CGFloat = 800
    private static let initialContentHeight: CGFloat = 98

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
    func present() -> Duration {
        let start = clock.now
        let panel = panel ?? createPanel()
        self.panel = panel

        model.prepareForPresentation()
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
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("com.padding.leap.launcher")
        panel.contentView = LauncherHostingView(
            rootView: LauncherView(model: model){ [weak panel] height in
                guard let panel else {
                    return
                }
                Self.resize(panel, toContentHeight: height)
            }
        )
        panel.center()
        return panel
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
