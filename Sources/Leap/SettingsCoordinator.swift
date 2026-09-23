import Observation
import LeapCore
import ServiceManagement
import SwiftUI
import YQLogger

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LoginItemState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }

    var detail: LocalizedStringKey? {
        switch self {
        case .disabled, .enabled: nil
        case .requiresApproval: "需要在系统设置中批准登录项。"
        case .unavailable: "系统无法读取登录项状态。"
        }
    }
}

@MainActor
@Observable
final class SettingsCoordinator {
    private static let logger = YQLogger(label: "com.padding.leap/settings")

    private let launcher: LauncherModel
    private let shortcutStore: HotKeyShortcutStore
    private let applyShortcut: (HotKeyShortcut) throws -> Void

    let pluginInstallation: PluginInstallationModel
    private(set) var shortcut: HotKeyShortcut
    private(set) var shortcutError: String?
    private(set) var loginItemState: LoginItemState
    private(set) var loginItemError: String?
    private(set) var isRebuildingApplicationIndex = false
    private(set) var dataMessage: String?

    init(
        paths: AppPaths,
        launcher: LauncherModel,
        shortcutStore: HotKeyShortcutStore = .init(),
        applyShortcut: @escaping (HotKeyShortcut) throws -> Void
    ) {
        self.launcher = launcher
        self.shortcutStore = shortcutStore
        self.applyShortcut = applyShortcut
        shortcut = shortcutStore.load()
        loginItemState = Self.currentLoginItemState()
        pluginInstallation = PluginInstallationModel(paths: paths) { [weak launcher] in
            launcher?.reloadPlugins()
        }
    }

    func updateShortcut(_ shortcut: HotKeyShortcut) {
        do {
            try applyShortcut(shortcut)
            shortcutStore.save(shortcut)
            self.shortcut = shortcut
            shortcutError = nil
        } catch {
            Self.logger.error("更新全局快捷键失败：\(error.localizedDescription)。")
            shortcutError = error.localizedDescription
        }
    }

    func restoreDefaultShortcut() {
        updateShortcut(.defaultValue)
    }

    func refreshLoginItemState() {
        loginItemState = Self.currentLoginItemState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            Self.logger.error("更新登录项失败：\(error.localizedDescription)。")
            loginItemError = error.localizedDescription
        }
        refreshLoginItemState()
    }

    func openSystemLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func clearRecentItems() {
        launcher.clearRecentItems()
        dataMessage = "已清除最近使用记录。"
    }

    func rebuildApplicationIndex() {
        guard !isRebuildingApplicationIndex else { return }
        isRebuildingApplicationIndex = true
        dataMessage = nil
        launcher.rebuildApplicationIndex { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRebuildingApplicationIndex = false
                switch result {
                case .success:
                    self.dataMessage = "系统应用索引已重建。"
                case let .failure(error):
                    Self.logger.error("重建系统应用索引失败：\(error.localizedDescription)。")
                    self.dataMessage = error.localizedDescription
                }
            }
        }
    }

    var canRebuildApplicationIndex: Bool {
        launcher.canRebuildApplicationIndex
    }

    private static func currentLoginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }
}
