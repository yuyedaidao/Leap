import AppKit
import OSLog
import SwiftUI

@MainActor
final class LauncherPanelController {
    private static let logger = Logger(subsystem: "com.padding.leap", category: "launcher-panel")

    private let clock = ContinuousClock()
    private let model: LauncherModel
    private var panel: NSWindow?

    init(model: LauncherModel) {
        self.model = model
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    @discardableResult
    func present() -> Duration {
        let start = clock.now
        let panel = panel ?? createPanel()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.requestSearchFocus()
        let elapsed = start.duration(to: clock.now)
        Self.logger.debug("已显示 Leap 搜索面板，耗时：\(String(describing: elapsed), privacy: .public)。")
        return elapsed
    }

    func meetsHotWakeBudget(iterations: Int = 20, budget: Duration = .milliseconds(200)) -> Bool {
        guard iterations > 0 else {
            return false
        }
        return (0..<iterations).allSatisfy { _ in present() < budget }
    }

    private func createPanel() -> NSWindow {
        let panel = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
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
        panel.contentView = NSHostingView(rootView: LauncherView(model: model))
        panel.center()
        return panel
    }
}

private final class LauncherWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        // Escape 只隐藏常驻面板，避免结束应用或破坏下一次快捷键唤起。
        orderOut(sender)
    }
}
