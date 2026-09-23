import Foundation
import LeapCore
import Observation
import YQLogger

@MainActor
@Observable
final class PluginInstallationModel {
    private static let logger = YQLogger(label: "com.padding.leap/plugin-installation-ui")

    private let installer: PluginInstaller
    private let catalog: InstalledPluginCatalog
    private let didInstall: () -> Void
    private var securityScopedDirectory: URL?

    private(set) var candidate: PluginInstallCandidate?
    private(set) var errorMessage: String?
    private(set) var plugins: [InstalledPluginDescriptor] = []
    var isConfirmationPresented = false

    init(paths: AppPaths, didInstall: @escaping () -> Void) {
        installer = PluginInstaller(paths: paths)
        catalog = InstalledPluginCatalog(paths: paths)
        self.didInstall = didInstall
        reloadPlugins()
    }

    func inspect(directory: URL, isSecurityScoped: Bool) {
        do {
            let candidate = try installer.inspect(sourceDirectory: directory)
            self.candidate = candidate
            errorMessage = nil
            securityScopedDirectory = isSecurityScoped ? directory : nil
            if installer.requiresConfirmation(for: candidate) {
                // 文件选择器授予的访问权限必须维持到用户确认后，复制才能读取源目录。
                isConfirmationPresented = true
            } else {
                try install(candidate, confirmed: false)
            }
        } catch {
            if securityScopedDirectory != nil {
                releaseSecurityScope()
            } else if isSecurityScoped {
                directory.stopAccessingSecurityScopedResource()
            }
            Self.logger.error("无法检查插件目录：\(error.localizedDescription)。")
            errorMessage = error.localizedDescription
        }
    }

    func confirmInstallation() {
        guard let candidate else {
            return
        }
        do {
            try install(candidate, confirmed: true)
        } catch {
            Self.logger.error("插件安装失败：\(error.localizedDescription)。")
            errorMessage = error.localizedDescription
        }
    }

    func rejectInstallation() {
        candidate = nil
        isConfirmationPresented = false
        releaseSecurityScope()
    }

    func inspectFailure(_ error: Error) {
        Self.logger.error("插件目录选择失败：\(error.localizedDescription)。")
        errorMessage = error.localizedDescription
    }

    func uninstall(_ plugin: InstalledPluginDescriptor) {
        do {
            try installer.uninstall(pluginID: plugin.id)
            reloadPlugins()
            didInstall()
            errorMessage = nil
        } catch {
            Self.logger.error("插件卸载失败：\(plugin.id)，\(error.localizedDescription)。")
            errorMessage = error.localizedDescription
        }
    }

    func reloadPlugins() {
        plugins = catalog.loadPlugins()
    }

    private func install(_ candidate: PluginInstallCandidate, confirmed: Bool) throws {
        defer { releaseSecurityScope() }
        _ = try installer.install(candidate, confirmed: confirmed)
        self.candidate = nil
        isConfirmationPresented = false
        reloadPlugins()
        didInstall()
    }

    private func releaseSecurityScope() {
        securityScopedDirectory?.stopAccessingSecurityScopedResource()
        securityScopedDirectory = nil
    }
}
