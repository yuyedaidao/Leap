import AppKit
import SwiftUI
import YQLogger

/// 保留 SwiftUI Settings 场景，仅协调原生窗口的 Space 与屏幕归属。
@MainActor
final class SettingsWindowPresenter {
    private weak var window: NSWindow?
    private var pendingScreen: NSScreen?
    private let logger = YQLogger(label: "com.padding.leap/settings-window")

    func prepare(on screen: NSScreen?) {
        pendingScreen = screen
        guard let window else { return }
        configure(window)
        position(window, on: screen)
        if window.isMiniaturized { window.deminiaturize(nil) }
        pendingScreen = nil
        // 复用窗口也要显式激活；仅打开 Settings 场景不能保证已有窗口获得焦点。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        logger.debug("已有设置窗口已激活并置前。")
    }

    func register(_ window: NSWindow) {
        self.window = window
        configure(window)
        guard let screen = pendingScreen else { return }
        pendingScreen = nil
        // 首次创建时等 SwiftUI 完成内容尺寸布局，再按实际窗口大小定位。
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            position(window, on: screen)
        }
    }

    private func configure(_ window: NSWindow) {
        window.setAccessibilityIdentifier("settings.window")
        // 在成为活动窗口时移到当前 Space，而不是让系统切换到旧 Space。
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    private func position(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            logger.debug("设置窗口未指定屏幕，使用系统默认位置。")
            return
        }
        guard window.screen?.leapDisplayID != screen.leapDisplayID || !window.isOnActiveSpace else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else {
            logger.error("无法定位设置窗口：目标屏幕可用范围无效。")
            return
        }
        // 只调整位置，不覆盖用户已有的窗口尺寸。
        window.setFrameOrigin(NSPoint(
            x: max(visible.minX, visible.midX - window.frame.width / 2),
            y: max(visible.minY, visible.midY - window.frame.height / 2)
        ))
        logger.debug("设置窗口已定位到启动器屏幕：\(screen.localizedName)。")
    }
}

struct SettingsWindowRegistration: NSViewRepresentable {
    let presenter: SettingsWindowPresenter

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(presenter: presenter)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        private let presenter: SettingsWindowPresenter

        init(presenter: SettingsWindowPresenter) {
            self.presenter = presenter
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presenter.register(window) }
        }
    }
}
