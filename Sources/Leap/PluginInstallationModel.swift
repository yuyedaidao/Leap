import Foundation
import LeapCore
import Observation
import YQLogger

/// 定向更新时防止把另一个插件的候选装进目标 ID。
private struct UpdateTargetMismatch: LocalizedError {
    let expectedID: String
    let actualID: String

    var errorDescription: String? {
        "所选插件的 ID（\(actualID)）与要更新的插件（\(expectedID)）不一致。请选择该插件的目录。"
    }
}

@MainActor
@Observable
final class PluginInstallationModel {
    private static let logger = YQLogger(label: "com.padding.leap/plugin-installation-ui")

    private let installer: PluginInstaller
    private let catalog: InstalledPluginCatalog
    private let enabledStore: PluginEnabledStore
    private let didInstall: () -> Void
    private let downloader: RemotePluginDownloader
    private var securityScopedDirectory: URL?
    private var downloadTask: Task<Void, Never>?
    private var downloadID: UUID?
    private var remoteDownload: RemotePluginDownload?
    private var updateTargetID: String?

    private(set) var candidate: PluginInstallCandidate?
    private(set) var errorMessage: String?
    private(set) var plugins: [InstalledPluginDescriptor] = []
    private(set) var disabledPluginIDs: Set<String> = []
    private(set) var progress: RemotePluginProgress?
    private(set) var remotePhase: String?
    private(set) var remoteInitialAddress = ""
    private(set) var isPreparing = false
    private(set) var isInstalling = false
    var isConfirmationPresented = false
    var isRemotePresented = false

    var isUpdating: Bool { updateTargetID != nil }

    init(
        paths: AppPaths,
        enabledStore: PluginEnabledStore = PluginEnabledStore(),
        downloader: RemotePluginDownloader = .init(),
        didInstall: @escaping () -> Void
    ) {
        installer = PluginInstaller(paths: paths)
        catalog = InstalledPluginCatalog(paths: paths, enabledStore: enabledStore)
        self.enabledStore = enabledStore
        self.downloader = downloader
        self.didInstall = didInstall
        reloadPlugins()
    }

    func isEnabled(_ plugin: InstalledPluginDescriptor) -> Bool {
        !disabledPluginIDs.contains(plugin.id)
    }

    /// 禁用只影响启动器索引，插件文件与信任记录保持不变。
    func setEnabled(_ enabled: Bool, for plugin: InstalledPluginDescriptor) {
        enabledStore.setEnabled(enabled, pluginID: plugin.id)
        disabledPluginIDs = enabledStore.disabledPluginIDs
        didInstall()
    }

    func inspect(directory: URL, isSecurityScoped: Bool, updating pluginID: String? = nil) {
        guard !isPreparing, !isInstalling, !isRemotePresented else {
            if isSecurityScoped { directory.stopAccessingSecurityScopedResource() }
            return
        }
        rejectInstallation()
        updateTargetID = pluginID
        securityScopedDirectory = isSecurityScoped ? directory : nil
        do {
            let candidate = try installer.inspect(sourceDirectory: directory)
            try validateUpdateTarget(for: candidate)
            self.candidate = candidate
            errorMessage = nil
            if isUpdating || installer.requiresConfirmation(for: candidate) {
                // 文件选择器授予的访问权限必须维持到用户确认后，复制才能读取源目录。
                isConfirmationPresented = true
            } else {
                try install(candidate, confirmed: false)
            }
        } catch {
            rejectInstallation()
            Self.logger.error("无法检查插件目录：\(error.localizedDescription)。")
            errorMessage = error.localizedDescription
        }
    }

    func confirmInstallation() {
        guard let candidate, !isInstalling else {
            return
        }
        if candidate.source == nil {
            do {
                try install(candidate, confirmed: true)
            } catch {
                rejectInstallation()
                installationFailed(error)
            }
            return
        }
        isInstalling = true
        remotePhase = "正在安装"
        let installer = installer
        // 安装提交不受表单取消打断；磁盘复制和摘要计算不占用主线程。
        Task { [self] in
            defer { isInstalling = false }
            do {
                _ = try await Task.detached(priority: .userInitiated) { try installer.install(candidate, confirmed: true) }.value
                finishInstallation()
                isRemotePresented = false
            } catch {
                installationFailed(error)
                clearCandidate()
                remotePhase = nil
                progress = nil
            }
        }
    }

    func rejectInstallation() {
        guard !isInstalling else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadID = nil
        isPreparing = false
        progress = nil
        remotePhase = nil
        updateTargetID = nil
        remoteInitialAddress = ""
        clearCandidate()
    }

    private func clearCandidate() {
        candidate = nil
        isConfirmationPresented = false
        releaseSecurityScope()
        remoteDownload?.remove()
        remoteDownload = nil
    }

    func presentRemoteInstallation(updating pluginID: String? = nil) {
        guard !isInstalling else { return }
        rejectInstallation()
        updateTargetID = pluginID
        if let pluginID, let record = try? installer.readTrustRecord(for: pluginID) {
            remoteInitialAddress = record.source?.directoryURL.absoluteString ?? ""
        }
        errorMessage = nil
        isRemotePresented = true
    }

    /// 商店安装不需要地址表单，直接按索引目录下载；已安装同 ID 时按定向更新校验。
    func installFromStore(address: String, pluginID: String) {
        guard !isPreparing, !isInstalling, candidate == nil else { return }
        updateTargetID = plugins.contains { $0.id == pluginID } ? pluginID : nil
        errorMessage = nil
        downloadRemote(address: address)
    }

    func downloadRemote(address: String) {
        guard !isPreparing, !isInstalling, candidate == nil else { return }
        let id = UUID()
        downloadID = id
        isPreparing = true
        errorMessage = nil
        remotePhase = "正在解析地址"
        let downloader = downloader
        let installer = installer
        downloadTask = Task { [weak self] in
            var result: RemotePluginDownload?
            defer { result?.remove() }
            do {
                let download = try await downloader.download(address: address) { [weak self] progress in
                    await self?.updateProgress(progress, id: id)
                }
                result = download
                try Task.checkCancellation()
                guard let self, downloadID == id else { return }
                remotePhase = "正在校验插件"
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try installer.inspect(sourceDirectory: download.directory, source: download.source)
                }.value
                try Task.checkCancellation()
                guard downloadID == id else { return }
                try validateUpdateTarget(for: inspected)
                candidate = inspected
                remoteDownload = download
                result = nil
                remotePhase = isUpdating ? "请确认更新来源" : "请确认安装来源"
                isPreparing = false
                downloadTask = nil
            } catch {
                guard let self, downloadID == id else { return }
                isPreparing = false
                downloadTask = nil
                remotePhase = nil
                progress = nil
                if !Task.isCancelled { installationFailed(error) }
            }
        }
    }

    private func validateUpdateTarget(for candidate: PluginInstallCandidate) throws {
        // 通用安装按候选 ID 写入，定向更新必须在候选进入确认流程前锁定同一 ID。
        if let updateTargetID, candidate.manifest.id != updateTargetID {
            throw UpdateTargetMismatch(expectedID: updateTargetID, actualID: candidate.manifest.id)
        }
    }

    private func updateProgress(_ progress: RemotePluginProgress, id: UUID) {
        guard downloadID == id else { return }
        self.progress = progress
        remotePhase = progress.phase == .resolving ? "正在解析地址" : "正在下载插件"
    }

    var replacementMessage: String? {
        guard let candidate, let existing = plugins.first(where: { $0.id == candidate.manifest.id }) else { return nil }
        let previous = try? installer.readTrustRecord(for: existing.id)
        let oldSource = previous?.source
        let sourceChanged = oldSource?.owner.lowercased() != candidate.source?.owner.lowercased() ||
            oldSource?.repository.lowercased() != candidate.source?.repository.lowercased() || oldSource?.path != candidate.source?.path
        var message = "将替换已安装的 \(existing.manifest.name) \(existing.manifest.version)。"
        if sourceChanged {
            message += "\n注意：插件来源发生变化。原来源：\(oldSource?.directoryURL.absoluteString ?? "本地目录")。"
        }
        return message
    }

    private func installationFailed(_ error: Error) {
        let message: String
        if let error = error as? URLError {
            message = error.code == .timedOut ? "下载超时，请检查网络后重试。" : "网络请求失败，请检查网络连接后重试。"
        } else {
            message = error.localizedDescription
        }
        Self.logger.error("插件安装失败：\(message)。")
        errorMessage = message
    }

    func inspectFailure(_ error: Error) {
        Self.logger.error("插件目录选择失败：\(error.localizedDescription)。")
        errorMessage = error.localizedDescription
    }

    func uninstall(_ plugin: InstalledPluginDescriptor) {
        do {
            try installer.uninstall(pluginID: plugin.id)
            // 卸载后清掉禁用记录，避免重装同一插件时莫名仍处于禁用状态。
            enabledStore.setEnabled(true, pluginID: plugin.id)
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
        disabledPluginIDs = enabledStore.disabledPluginIDs
    }

    private func install(_ candidate: PluginInstallCandidate, confirmed: Bool) throws {
        defer { releaseSecurityScope() }
        _ = try installer.install(candidate, confirmed: confirmed)
        finishInstallation()
    }

    private func finishInstallation() {
        clearCandidate()
        updateTargetID = nil
        remoteInitialAddress = ""
        remotePhase = nil
        progress = nil
        errorMessage = nil
        reloadPlugins()
        didInstall()
    }

    private func releaseSecurityScope() {
        securityScopedDirectory?.stopAccessingSecurityScopedResource()
        securityScopedDirectory = nil
    }
}
