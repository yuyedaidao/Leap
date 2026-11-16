import AppKit
import LeapCore
import YQLogger

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = YQLogger(label: "com.padding.leap/app")
    let appUpdates = AppUpdateController(
        persistsPreferences: !ProcessInfo.processInfo.arguments.contains("-leap-testing-support-directory")
    )
    let settingsWindowPresenter = SettingsWindowPresenter()
    private var launcherPanelController: LauncherPanelController?
    private var globalHotKey: GlobalHotKey?
    private(set) var settingsCoordinator: SettingsCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedAppearance = UserDefaults.standard.string(forKey: "appearancePreference")
        applyAppearancePreference(AppearancePreference(rawValue: savedAppearance ?? "") ?? .system)

        do {
            let paths = try makePaths()
            let model = LauncherModel(paths: paths)
            model.startApplicationIndexing()
            let launcherPanelController = LauncherPanelController(model: model)
            self.launcherPanelController = launcherPanelController
            launcherPanelController.settingsRequested = { [weak self] screen in
                self?.showSettings(on: screen, source: "启动器")
            }

            Task { @MainActor in
#if DEBUG
                // 隔离 UI 测试固定主屏，避免 XCTest 在副屏的坐标转换及取词浮层干扰。
                let testingDisplay = ProcessInfo.processInfo.arguments.contains("-leap-testing-support-directory")
                    ? CGMainDisplayID() : nil
                launcherPanelController.present(on: testingDisplay)
#else
                launcherPanelController.present()
#endif
                presentTestingWebPlugin(in: model)

                if ProcessInfo.processInfo.arguments.contains("-measure-hot-wakes") {
                    let meetsBudget = launcherPanelController.meetsHotWakeBudget()
                    logger.info("20 次热唤起均在 200ms 内：\(meetsBudget)")
                }
            }

            let shortcutStore = HotKeyShortcutStore()
            let hotKey = makeGlobalHotKey()
            do {
                try hotKey.register(shortcutStore.load())
                globalHotKey = hotKey
            } catch {
                logger.error(error.localizedDescription)
            }
            settingsCoordinator = SettingsCoordinator(
                paths: paths,
                launcher: model,
                shortcutStore: shortcutStore,
                applyShortcut: { [weak self] shortcut in
                    guard let self else {
                        throw AppDelegateError.unavailable
                    }
                    try self.replaceGlobalHotKey(with: shortcut)
                }
            )
        } catch {
            logger.error("无法初始化 Leap 数据目录：\(error.localizedDescription)。")
        }
        startAppUpdates()
    }

    private func startAppUpdates() {
        appUpdates.willPresentUpdate = { [weak self] in
            guard let self else { return }
            launcherPanelController?.hideForUpdate()
            settingsWindowPresenter.prepareForUpdate()
            // 设置与启动器都是非激活面板，应用不激活时 Sparkle 的弹窗会落到上次活跃的空间或主屏上，
            // 表现为“点了检查更新但没反应”。先激活应用，再把弹窗并入设置所在的当前空间。
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                self.placeUpdateWindowsBesideSettings()
            }
        }
        // UI 测试不能访问真实更新源或替换正在运行的应用。
        if !ProcessInfo.processInfo.arguments.contains("-leap-testing-support-directory") {
            appUpdates.start()
        }
    }

    /// Sparkle 的窗口与本应用同进程，直接把它挪到当前空间和设置所在屏幕，避免弹窗出现在别的屏幕/空间。
    private func placeUpdateWindowsBesideSettings() {
        let settings = settingsWindowPresenter.window
        let screen = settings?.screen
            ?? NSScreen.leapScreen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main
        for window in NSApp.windows where window.isVisible && Self.isUpdateWindow(window) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            guard let screen else { continue }
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2
            ))
        }
    }

    // Sparkle 的弹窗由 SU/SPU 开头的窗口控制器持有（SUUpdateAlert、SUStatusController 等），借此只动更新弹窗。
    private static func isUpdateWindow(_ window: NSWindow) -> Bool {
        let controller = window.windowController.map { String(describing: type(of: $0)) }
            ?? String(describing: type(of: window))
        return controller.hasPrefix("SU") || controller.hasPrefix("SPU")
    }

    func showSettings(on screen: NSScreen? = nil, source: String) {
        settingsWindowPresenter.present(on: screen, source: source) {
            LeapSettingsRootView(appDelegate: self)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey?.unregister()
        launcherPanelController?.closePluginSessions()
        PluginProcessSession.terminateAll()
    }

    func applyAppearancePreference(_ preference: AppearancePreference) {
        // 外观要设在 NSApplication 上，才能同时影响 Settings 的标题栏和 SwiftUI 内容，
        // 而不是只让内容区域与窗口装饰处于不同主题。
        NSApp.appearance = preference.appKitAppearance
    }

    private func makePaths() throws -> AppPaths {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-leap-testing-support-directory"),
           arguments.indices.contains(index + 1),
           let resources = Bundle.main.resourceURL {
            // UI 测试通过独立目录安装样例，不能触及用户真实的插件与信任记录。
            return AppPaths(
                applicationSupportDirectory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true),
                resourceDirectory: resources
            )
        }
#endif
        return try AppPaths()
    }

    private func presentTestingWebPlugin(in model: LauncherModel) {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // 仅在隔离数据目录下启用 UI 测试启动夹具，仍走实际安装索引与正常打开路径。
        guard arguments.contains("-leap-testing-support-directory"),
              let index = arguments.firstIndex(of: "-leap-testing-open-plugin"),
              arguments.indices.contains(index + 1) else { return }
        model.reloadPlugins()
        if let command = model.commands.first(where: {
            $0.manifest.id == arguments[index + 1]
        }) {
            model.activate(command)
        }
#endif
    }

    private func makeGlobalHotKey() -> GlobalHotKey {
        GlobalHotKey { [weak self] targetDisplayID, fallbackLocation in
            self?.launcherPanelController?.present(
                on: targetDisplayID,
                fallbackLocation: fallbackLocation
            )
        }
    }

    private func replaceGlobalHotKey(with shortcut: HotKeyShortcut) throws {
        let previousHotKey = globalHotKey
        let previousShortcut = previousHotKey?.shortcut
        previousHotKey?.unregister()

        let replacement = makeGlobalHotKey()
        do {
            try replacement.register(shortcut)
            globalHotKey = replacement
        } catch {
            if let previousHotKey, let previousShortcut {
                do {
                    try previousHotKey.register(previousShortcut)
                    globalHotKey = previousHotKey
                } catch {
                    logger.error("恢复旧全局快捷键失败：\(error.localizedDescription)。")
                    globalHotKey = nil
                }
            }
            throw error
        }
    }
}

private enum AppDelegateError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Leap 尚未完成初始化，无法更新全局快捷键。"
    }
}
