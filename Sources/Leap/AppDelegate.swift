import AppKit
import LeapCore
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.padding.leap", category: "app")
    private var launcherPanelController: LauncherPanelController?
    private var globalHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = try makePaths()
            let model = LauncherModel(paths: paths)
            let launcherPanelController = LauncherPanelController(model: model)
            self.launcherPanelController = launcherPanelController

            Task { @MainActor in
                launcherPanelController.present()

                if ProcessInfo.processInfo.arguments.contains("-measure-hot-wakes") {
                    let meetsBudget = launcherPanelController.meetsHotWakeBudget()
                    logger.info("20 次热唤起均在 200ms 内：\(meetsBudget)")
                }
            }

            let hotKey = GlobalHotKey { [weak launcherPanelController] in
                launcherPanelController?.present()
            }
            do {
                try hotKey.registerOptionSpace()
                globalHotKey = hotKey
            } catch {
                logger.error("\(error.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.error("无法初始化 Leap 数据目录：\(error.localizedDescription, privacy: .public)。")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // SwiftUI 场景仅维持应用生命周期；每次激活后都确保它不会成为第二个启动器窗口。
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.identifier?.rawValue != "com.padding.leap.launcher" }
                .forEach { $0.orderOut(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey?.unregister()
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
}
