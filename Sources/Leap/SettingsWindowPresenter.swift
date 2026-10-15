import AppKit
import SwiftUI
import YQLogger

/// 设置内容仍由 SwiftUI 展示，窗口复用启动器的原生面板定位与 Space 行为。
@MainActor
final class SettingsWindowPresenter {
    private var panel: SettingsPanel?
    private let logger = YQLogger(label: "com.padding.leap/settings-window")

    init() {
        // 非激活面板不会经历应用失活通知；切换到其他应用时仍需撤销临时置顶。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let panel, panel.level != .normal else { return }
        panel.level = .normal
        logger.debug("已切换到其他应用，设置恢复普通窗口层级。")
    }

    func present(on screen: NSScreen? = nil, source: String, content: () -> LeapSettingsRootView) {
        let target = resolveScreen(preferredDisplayID: screen?.leapDisplayID)
        let isNew = panel == nil
        let panel = panel ?? makePanel(content: content())
        self.panel = panel
        show(panel, on: target, source: source, isNew: isNew)
    }

    private func makePanel(content: LeapSettingsRootView) -> SettingsPanel {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        // 保留原生标题展示，让 SwiftUI 的 navigationTitle 随详情页更新。
        panel.titlebarAppearsTransparent = true
        // macOS 的紧凑工具栏会把侧栏边界下移；统一样式才能将系统按钮融入完整侧栏。
        panel.toolbarStyle = .unified
        panel.titlebarSeparatorStyle = .none
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.setAccessibilityIdentifier("settings.window")
        let hostingView = NSHostingView(rootView: content)
        // 内容只提供最小尺寸，默认尺寸和用户缩放后的尺寸仍由面板管理。
        hostingView.sizingOptions = [.minSize]
        panel.contentView = hostingView
        // 限制内容尺寸，保证侧栏与右侧现有控件在缩小时仍可操作。
        panel.contentMinSize = NSSize(width: 860, height: 500)
        panel.reopenRequested = { [weak self, weak panel] in
            guard let self, let panel else { return }
            // 已持有焦点时只更新层级，避免重复交接并保留选中的设置页。
            panel.level = .floating
            logger.debug("设置快捷键已确认当前面板，保留页面与键盘焦点。")
        }
        return panel
    }

    private func show(_ panel: SettingsPanel, on screen: NSScreen?, source: String, isNew: Bool) {
        let wasOnActiveSpace = panel.isOnActiveSpace
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        position(panel, on: screen, preservePosition: !isNew && wasOnActiveSpace)
        // 与启动器一致：只让非激活面板取得键盘焦点。激活应用会离开其他应用的全屏 Space。
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        logger.debug(
            "设置面板已展示：入口=\(source)，屏幕=\(screen?.localizedName ?? "未知")，"
                + "当前空间=\(panel.isOnActiveSpace)，键盘焦点=\(panel.isKeyWindow)。"
        )
    }

    private func resolveScreen(preferredDisplayID: CGDirectDisplayID?) -> NSScreen? {
        if let preferredDisplayID,
           let screen = NSScreen.screens.first(where: { $0.leapDisplayID == preferredDisplayID }) {
            return screen
        }
        let mouseScreen = NSScreen.leapScreen(containing: NSEvent.mouseLocation)
        let displayID = WindowDisplayResolver.frontmostWindowDisplayID(fallbackDisplayID: mouseScreen?.leapDisplayID)
        if let displayID,
           let screen = NSScreen.screens.first(where: { $0.leapDisplayID == displayID }) {
            return screen
        }
        return mouseScreen ?? NSScreen.main
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?, preservePosition: Bool) {
        guard let screen else {
            logger.error("无法确定设置窗口的目标屏幕，保留现有位置。")
            return
        }
        guard !preservePosition || panel.screen?.leapDisplayID != screen.leapDisplayID else { return }
        let visible = screen.visibleFrame
        guard visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0 else {
            logger.error("无法定位设置窗口：目标屏幕可用范围无效。")
            return
        }
        // 只调整位置，不覆盖用户已有的窗口尺寸。
        panel.setFrameOrigin(NSPoint(
            x: max(visible.minX, visible.midX - panel.frame.width / 2),
            y: max(visible.minY, visible.midY - panel.frame.height / 2)
        ))
    }
}

private final class SettingsPanel: NSPanel {
    private static let logger = YQLogger(label: "com.padding.leap/settings-window")
    var reopenRequested: (() -> Void)?
    override var canBecomeKey: Bool { true }
    // 全屏应用继续作为主应用，设置面板独立接收键盘输入，避免系统切回 Leap 的桌面。
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if isKeyWindow, attachedSheet == nil, event.type == .keyDown, modifiers == .command {
            // 自建面板的关闭和重开快捷键在窗口内处理，不依赖 SwiftUI 场景的窗口注册。
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                performClose(nil)
                return true
            case ",":
                reopenRequested?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        // 等焦点交接完成再降层，避免输入框切换或原生 sheet 暂时接管焦点时误降层。
        Task { @MainActor [weak self] in
            guard let self, !isKeyWindow, attachedSheet == nil, level != .normal else { return }
            level = .normal
            Self.logger.debug("设置失去键盘焦点，已恢复普通窗口层级。")
        }
    }
}
