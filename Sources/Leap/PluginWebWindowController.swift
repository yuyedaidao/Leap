import AppKit
import Carbon.HIToolbox
import LeapCore
import SwiftUI
import YQLogger

/// 仅管理插件窗口生命周期；网页调用和目录授权仍由 PluginWebView 处理。
@MainActor
final class PluginWebWindowController: NSObject, NSWindowDelegate {
    private var window: PluginWindow?
    private var session: PluginInteractionSession?
    private var onClose: ((Bool) -> Void)?
    private var restoresLauncher = true
    private var minimumContentSize = NSSize(width: 400, height: 300)
    private let logger = YQLogger(label: "com.padding.leap/plugin-window")

    func present(
        command: PluginCommandDescriptor,
        session: PluginInteractionSession,
        on screen: NSScreen?,
        onClose: @escaping (Bool) -> Void
    ) {
        let window = window ?? makeWindow()
        self.window = window
        self.session?.close()
        self.session = session
        restoresLauncher = true
        session.hostAction = { [weak self] method in
            if method == "hideMainWindow" || PluginHostAPI.inputMethods.contains(method) { self?.restoresLauncher = false }
            if method == "outPlugin" || method == "hideMainWindow" || PluginHostAPI.inputMethods.contains(method) {
                self?.window?.close()
            }
        }
        self.onClose = onClose
        window.title = command.title
        let content = PluginWebContent(command: command, session: session)
        let hosting = NSHostingController(rootView: content)
        // 默认大小由清单决定，不能被 SwiftUI 的理想尺寸重新覆盖。
        hosting.sizingOptions = []
        window.contentViewController = hosting
        configureSize(window, manifest: command.manifest, screen: screen ?? NSScreen.main)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        logger.debug("已打开网页插件窗口：\(command.manifest.id)。")
    }

    func windowWillClose(_ notification: Notification) {
        logger.debug("已关闭网页插件窗口。")
        let callback = onClose
        onClose = nil
        session?.close()
        session = nil
        // 关闭时释放网页及其桥接授权，不让隐藏页面继续占用资源或发送请求。
        window?.contentViewController = nil
        callback?(restoresLauncher)
    }

    var isVisible: Bool { window?.isVisible == true }

    func setInputHidden(_ hidden: Bool) {
        if hidden { window?.orderOut(nil) }
        else { NSApp.activate(); window?.makeKeyAndOrderFront(nil) }
    }

    func close() { restoresLauncher = false; window?.close(); session?.close(); session = nil }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // NSHostingController 布局可能重设系统最小尺寸；拖动边界仍由宿主明确限制。
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    private func makeWindow() -> PluginWindow {
        let window = PluginWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // 继承启动器所在的当前 Space；再次激活时不能跳回应用旧窗口所属的桌面。
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier("plugin.webWindow")
        window.delegate = self
        return window
    }

    private func configureSize(_ window: NSWindow, manifest: PluginManifest, screen: NSScreen?) {
        let requested = manifest.webWindow ?? .init(width: 560, height: 360)
        let available = screen.map { window.contentRect(forFrameRect: $0.visibleFrame).size }
            ?? NSSize(width: 560, height: 360)
        // 极小屏幕优先保证窗口可见；普通屏幕仍使用约定的 400 × 300 最小内容尺寸。
        minimumContentSize = NSSize(width: min(400, available.width), height: min(300, available.height))
        window.contentMinSize = minimumContentSize
        window.setContentSize(NSSize(
            width: min(CGFloat(requested.width), available.width),
            height: min(CGFloat(requested.height), available.height)
        ))
        if let screen {
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
    }
}

private final class PluginWindow: NSWindow {
    private var closesOnEscapeRelease = false

    override func sendEvent(_ event: NSEvent) {
        // 消耗整组 Escape 按键事件，再关闭窗口，避免剩余事件落入恢复后的启动器。
        if attachedSheet == nil, event.type == .keyDown || event.type == .keyUp,
           event.keyCode == UInt16(kVK_Escape) {
            if event.type == .keyDown {
                closesOnEscapeRelease = true
                return
            }
            if event.type == .keyUp, closesOnEscapeRelease {
                closesOnEscapeRelease = false
                close()
                return
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        closesOnEscapeRelease = false
        super.resignKey()
    }

    override func cancelOperation(_ sender: Any?) {
        if closesOnEscapeRelease {
            return
        }
        close()
    }
}
