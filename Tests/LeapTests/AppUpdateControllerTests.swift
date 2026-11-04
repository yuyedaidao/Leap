import Foundation
import Testing

@MainActor
struct AppUpdateControllerTests {
    @MainActor
    final class Updater: AppUpdating {
        var canCheckForUpdates = true
        var starts = 0
        var backgroundChecks = 0
        var manualChecks = 0
        var fails = false
        func start() throws {
            starts += 1
            if fails { throw CocoaError(.fileReadUnknown) }
        }
        func checkForUpdates() { manualChecks += 1; canCheckForUpdates = false }
        func checkForUpdatesInBackground() { backgroundChecks += 1 }
    }

    @Test("默认开启且每次启动只检查一次，开关修改不会立即联网")
    func startupOnce() throws {
        let name = "LeapUpdatesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = Updater()
        let model = AppUpdateController(defaults: defaults, updater: backend)
        #expect(model.automaticallyChecksOnLaunch)
        model.start()
        model.start()
        #expect(backend.starts == 1)
        #expect(backend.backgroundChecks == 1)
        model.automaticallyChecksOnLaunch = false
        #expect(!AppUpdateController(defaults: defaults, updater: Updater()).automaticallyChecksOnLaunch)
        #expect(backend.backgroundChecks == 1)
        let transient = AppUpdateController(defaults: defaults, updater: Updater(), persistsPreferences: false)
        transient.automaticallyChecksOnLaunch = true
        #expect(!defaults.bool(forKey: AppUpdateController.preferenceKey))
    }

    @Test("关闭自动检查仍可手动检查，重复点击不创建并行会话")
    func manualChecks() throws {
        let name = "LeapUpdatesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: AppUpdateController.preferenceKey)
        let backend = Updater()
        let model = AppUpdateController(defaults: defaults, updater: backend)
        model.start()
        #expect(backend.backgroundChecks == 0)
        model.checkForUpdates()
        model.checkForUpdates()
        #expect(backend.manualChecks == 1)
    }

    @Test("初始化失败不请求更新，并提供错误信息")
    func initializationFailure() throws {
        let name = "LeapUpdatesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = Updater()
        backend.fails = true
        let model = AppUpdateController(defaults: defaults, updater: backend)
        model.start()
        model.checkForUpdates()
        #expect(model.errorMessage != nil)
        #expect(!model.canCheckForUpdates)
        #expect(backend.backgroundChecks == 0)
        #expect(backend.manualChecks == 0)
    }
}
