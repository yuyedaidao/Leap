import AppKit
import Observation
import Sparkle
import YQLogger

@MainActor
protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func start() throws
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

extension SPUUpdater: AppUpdating {}

/// 只在启动时检查；不能把这个偏好绑定到 Sparkle 的周期调度开关。
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    static let preferenceKey = "automaticallyChecksForUpdatesOnLaunch"
    private let defaults: UserDefaults
    private let persistsPreferences: Bool
    private let logger = YQLogger(label: "com.padding.leap/updates")
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var updater: (any AppUpdating)?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private var started = false
    private(set) var canCheckForUpdates = false
    private(set) var errorMessage: String?
    var willPresentUpdate: (() -> Void)?
    var automaticallyChecksOnLaunch: Bool {
        didSet {
            if persistsPreferences { defaults.set(automaticallyChecksOnLaunch, forKey: Self.preferenceKey) }
        }
    }

    init(
        defaults: UserDefaults = .standard, updater: (any AppUpdating)? = nil, persistsPreferences: Bool = true
    ) {
        self.defaults = defaults
        self.persistsPreferences = persistsPreferences
        self.updater = updater
        defaults.register(defaults: [Self.preferenceKey: true])
        automaticallyChecksOnLaunch = defaults.bool(forKey: Self.preferenceKey)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        if updater == nil {
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
            )
            self.controller = controller
            updater = controller.updater
            observation = controller.updater.observe(
                \.canCheckForUpdates, options: [.initial, .new]
            ) { [weak self] updater, _ in
                // Sparkle 的更新器 API 和 KVO 通知均在主线程交付。
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            }
        }
        do {
            try updater?.start()
            canCheckForUpdates = updater?.canCheckForUpdates == true
            if automaticallyChecksOnLaunch {
                logger.info("开始启动更新检查。")
                updater?.checkForUpdatesInBackground()
            }
        } catch {
            errorMessage = "更新模块初始化失败：\(error.localizedDescription)"
            canCheckForUpdates = false
            logger.error(errorMessage ?? "更新模块初始化失败。")
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
        canCheckForUpdates = updater?.canCheckForUpdates == true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error { logger.debug("更新检查结束：\(error.localizedDescription)。") }
    }

    func standardUserDriverWillShowModalAlert() { willPresentUpdate?() }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate { willPresentUpdate?() }
    }
}
