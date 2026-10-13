import AppKit
import CoreGraphics
import LeapCore
import YQLogger
import SwiftUI

@MainActor
final class LauncherPanelController {
    private static let logger = YQLogger(label: "com.padding.leap/launcher-panel")
    private static let contentWidth: CGFloat = 800
    // 搜索栏高度 70 加上上下各 24 的内边距，避免首帧布局后再调整窗口高度。
    private static let initialContentHeight: CGFloat = 118
    private static let verticalPositionFromTop: CGFloat = 1 / 3

    var settingsRequested: ((NSScreen?) -> Void)?

    private let clock = ContinuousClock()
    private let model: LauncherModel
    private var panel: LauncherPanel?
    private let pluginWindowController = PluginWebWindowController()
    private var inputWasStandalone = false

    init(model: LauncherModel) {
        self.model = model
        model.inputWindowVisibility = { [weak self] hidden in
            guard let self else { return }
            if hidden {
                self.inputWasStandalone = self.pluginWindowController.isVisible
                self.panel?.orderOut(nil)
                self.pluginWindowController.setInputHidden(true)
            } else if self.inputWasStandalone {
                self.pluginWindowController.setInputHidden(false)
            } else {
                self.panel?.makeKeyAndOrderFront(nil)
            }
        }
        model.hostAPI?.configureNotifications()
        model.hostAPI?.notificationCommand = { [weak self] pluginID, commandID in
            guard let self else { return }
            self.model.reloadPlugins()
            guard let command = self.model.commands.first(where: { $0.pluginID == pluginID && $0.commandID == commandID }) else { return }
            self.present()
            self.model.activate(command)
        }
        model.hideRequested = { [weak self] in self?.panel?.orderOut(nil) }
        model.applicationDidLaunch = { [weak self] in self?.hideAfterApplicationLaunch() }
        model.webPluginRequested = { [weak self] command in
            self?.presentWebPlugin(command)
        }
    }

    func closePluginSessions() {
        model.exitInteraction()
        model.closeActionSession()
        pluginWindowController.close()
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
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            model.externalTargetPID = application.processIdentifier
        }
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
        model.exitInteraction()
        panel?.orderOut(nil)
    }

    private func presentWebPlugin(_ command: PluginCommandDescriptor) {
        let screen = panel?.screen
        panel?.orderOut(nil)
        pluginWindowController.present(
            command: command, session: model.makeWebSession(command),
            on: screen,
            onClose: { [weak self] restore in
                guard let self else { return }
                model.dismissWebPlugin()
                guard restore else { return }
                let keyboardClose = NSApp.currentEvent.map { $0.type == .keyDown || $0.type == .keyUp } ?? false
                // 按键关闭主窗口时 AppKit 会异步归还焦点；让这次交接结束后再恢复非激活面板。
                Task { @MainActor [weak self] in
                    if keyboardClose {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard let self, model.webCommand == nil else { return }
                    panel?.makeKeyAndOrderFront(nil)
                    model.requestSearchFocus()
                    Self.logger.debug("插件关闭后已恢复启动器，键盘焦点：\(panel?.isKeyWindow ?? false)。")
                }
            }
        )
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
        // 让原生玻璃呈现窗口后方的内容，避免被 NSPanel 的默认底色遮住。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        // 收起由 resignKey 统一管理；关闭最后一个普通插件窗口时，应用失活不应自动隐藏刚恢复的面板。
        panel.hidesOnDeactivate = false
        // 启动器应跟随当前 Mission Control 桌面，而非永久附着在首次创建时的空间。
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("com.padding.leap.launcher")
        panel.preservesHostCall = { [weak model] in (model?.hostAPI?.pendingCalls ?? 0) > 0 }
        panel.activateListShortcut = { [weak model] in model?.activateListShortcut(at: $0, isRepeat: $1) ?? false }
        panel.exitInteraction = { [weak model] in
            guard let model, model.interaction != nil else { return false }
            model.exitInteraction()
            return true
        }
        panel.contentView = LauncherHostingView(
            rootView: LauncherView(model: model) { [weak panel, weak model] height in
                guard let panel else {
                    return
                }
                Self.resize(panel, toContentHeight: height, keepWithinScreen: model?.interaction != nil)
            } showSettings: { [weak self, weak panel] in
                let screen = panel?.screen
                // 先隐藏启动器，再交给设置面板接管键盘焦点。
                panel?.orderOut(nil)
                self?.settingsRequested?(screen)
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

    private static func resize(_ panel: NSWindow, toContentHeight height: CGFloat, keepWithinScreen: Bool) {
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
        if keepWithinScreen, let visibleFrame = panel.screen?.visibleFrame {
            // 长页面可向上让位，避免固定搜索栏顶边后把底部按钮推到屏幕外。
            targetFrame.origin.y = max(visibleFrame.minY + 12, targetFrame.origin.y)
        }
        panel.setFrame(targetFrame, display: true, animate: false)
    }
}

private final class LauncherHostingView: NSHostingView<LauncherView> {
    // fullSizeContentView 让 SwiftUI 内容与窗口 frame 等高，标题栏不应再作为安全区参与布局：
    // 否则 SwiftUI 会把标题栏高度追加到窗口高度上，在材质背景下方留出一条空白。
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

private final class LauncherPanel: NSPanel {
    private static let logger = YQLogger(label: "com.padding.leap/launcher-panel")
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var exitInteraction: (() -> Bool)?
    var preservesHostCall: (() -> Bool)?
    var activateListShortcut: ((Int, Bool) -> Bool)?
    private var consumesEscape = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isComposing = (firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
        if isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil, !isComposing, event.type == .keyDown,
           let key = event.charactersIgnoringModifiers,
           let index = LauncherListShortcut.index(for: key, modifiers: event.modifierFlags) {
            // 在窗口层处理，避免 LazyVStack 未挂载的第九、十项没有快捷键。
            if activateListShortcut?(index, event.isARepeat) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        let isEscape = (event.type == .keyDown || event.type == .keyUp) && event.keyCode == 53
        let isComposing = (firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
        if attachedSheet == nil, isEscape, !isComposing {
            if event.type == .keyDown {
                consumesEscape = true
                return
            }
            if consumesEscape {
                consumesEscape = false
                if exitInteraction?() != true { orderOut(nil) }
                return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if exitInteraction?() == true { return }
        Self.logger.debug("启动器收到取消操作，已收起。")
        // Escape 只隐藏常驻面板，避免结束应用或破坏下一次快捷键唤起。
        orderOut(sender)
    }

    override func resignKey() {
        super.resignKey()
        consumesEscape = false
        // 原生目录sheet归还焦点前，父面板和插件会话必须保留。
        guard attachedSheet == nil else { return }
        // 更换输入框时 AppKit 会短暂交还焦点；本轮交接结束后再判断是否真的离开面板。
        Task { @MainActor [weak self] in
            guard let self, !isKeyWindow, attachedSheet == nil, isVisible, preservesHostCall?() != true else { return }
            _ = exitInteraction?()
            Self.logger.debug("启动器失去键盘焦点，已收起。")
            orderOut(nil)
        }
    }
}
