import CryptoKit
import Foundation
@preconcurrency import YQLogger

public struct PluginTrustRecord: Codable, Equatable, Sendable {
    public let pluginID: String
    public let version: String
    public let contentDigest: String
    public let digestVersion: Int?
    public let source: RemotePluginSource?

    public init(pluginID: String, version: String, contentDigest: String, digestVersion: Int? = nil, source: RemotePluginSource? = nil) {
        self.pluginID = pluginID
        self.version = version
        self.contentDigest = contentDigest
        self.digestVersion = digestVersion
        self.source = source
    }
}

public struct PluginInstallCandidate: Equatable, Sendable {
    public let sourceDirectory: URL
    public let manifest: PluginManifest
    public let contentDigest: String
    public let source: RemotePluginSource?

    public init(sourceDirectory: URL, manifest: PluginManifest, contentDigest: String, source: RemotePluginSource? = nil) {
        self.sourceDirectory = sourceDirectory
        self.manifest = manifest
        self.contentDigest = contentDigest
        self.source = source
    }
}

public struct PluginInstaller: Sendable {
    public enum InstallationError: LocalizedError {
        case officialPluginReserved
        case confirmationRequired
        case managedDirectoryEscape
        case candidateChanged
        case unsupportedDigest
        case identifierCollision

        public var errorDescription: String? {
            switch self {
            case .officialPluginReserved: "内置插件随 Leap 更新，不能本地覆盖或卸载。"
            case .confirmationRequired: "插件内容尚未获得确认。"
            case .managedDirectoryEscape: "受管插件目录不安全。"
            case .candidateChanged: "插件内容在确认后发生变化，请重新选择并确认。"
            case .unsupportedDigest: "插件信任记录使用了不支持的摘要版本，请重新安装。"
            case .identifierCollision: "插件 ID 与本机已有插件的目录名称冲突，请使用不同的 ID。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/plugin-installer")

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func inspect(
        sourceDirectory: URL, source: RemotePluginSource? = nil, fileManager: FileManager = .default
    ) throws -> PluginInstallCandidate {
        let manifest = try PluginManifestValidator().load(from: sourceDirectory, fileManager: fileManager)
        guard !AppPaths.isOfficialPluginID(manifest.id) else { throw InstallationError.officialPluginReserved }
        _ = try paths.managedPluginDirectory(for: manifest.id)
        return PluginInstallCandidate(
            sourceDirectory: sourceDirectory.standardizedFileURL,
            manifest: manifest,
            contentDigest: try contentDigest(of: sourceDirectory, fileManager: fileManager),
            source: source
        )
    }

    public func requiresConfirmation(
        for candidate: PluginInstallCandidate,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let record = try? readTrustRecord(for: candidate.manifest.id, fileManager: fileManager) else {
            return true
        }
        // 远程候选始终展示来源，旧摘要也不能静默升级为覆盖隐藏文件的新信任。
        return candidate.source != nil || record.digestVersion != 2 || record.source != candidate.source ||
            record.version != candidate.manifest.version || record.contentDigest != candidate.contentDigest
    }

    @discardableResult
    public func install(
        _ candidate: PluginInstallCandidate,
        confirmed: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !AppPaths.isOfficialPluginID(candidate.manifest.id) else {
            throw InstallationError.officialPluginReserved
        }
        guard confirmed || !requiresConfirmation(for: candidate, fileManager: fileManager) else {
            throw InstallationError.confirmationRequired
        }

        try paths.createManagedDirectories(fileManager: fileManager)
        let destination = try paths.managedPluginDirectory(for: candidate.manifest.id)
        guard destination.deletingLastPathComponent().standardizedFileURL == paths.pluginsDirectory.standardizedFileURL else {
            throw InstallationError.managedDirectoryEscape
        }
        if let existing = try? PluginManifestValidator().load(from: destination, fileManager: fileManager),
           existing.id != candidate.manifest.id {
            // 默认 APFS 不区分大小写，不能用另一个 ID 意外覆盖已有插件。
            throw InstallationError.identifierCollision
        }

        let stagingDirectory = paths.pluginsDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        try fileManager.copyItem(at: candidate.sourceDirectory, to: stagingDirectory)
        let copied = try inspect(sourceDirectory: stagingDirectory, source: candidate.source, fileManager: fileManager)
        guard copied.manifest == candidate.manifest, copied.contentDigest == candidate.contentDigest else {
            throw InstallationError.candidateChanged
        }

        let record = PluginTrustRecord(
            pluginID: candidate.manifest.id,
            version: candidate.manifest.version,
            contentDigest: candidate.contentDigest,
            digestVersion: 2,
            source: candidate.source
        )
        let recordURL = try paths.trustRecordURL(for: candidate.manifest.id)
        let recordData = try JSONEncoder().encode(record)
        let transaction = paths.applicationSupportDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
        var preserveBackup = false
        defer { if !preserveBackup { try? fileManager.removeItem(at: transaction) } }
        let pluginBackup = transaction.appendingPathComponent("plugin", isDirectory: true)
        let trustBackup = transaction.appendingPathComponent("trust.json")
        let pendingTrust = transaction.appendingPathComponent("pending.json")
        try recordData.write(to: pendingTrust, options: .atomic)
        var movedPlugin = false
        var movedTrust = false
        var committedPlugin = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: pluginBackup)
                movedPlugin = true
            }
            if fileManager.fileExists(atPath: recordURL.path) {
                try fileManager.moveItem(at: recordURL, to: trustBackup)
                movedTrust = true
            }
            try fileManager.moveItem(at: stagingDirectory, to: destination)
            committedPlugin = true
            try fileManager.moveItem(at: pendingTrust, to: recordURL)
        } catch {
            do {
                if committedPlugin { try fileManager.removeItem(at: destination) }
                if movedPlugin { try fileManager.moveItem(at: pluginBackup, to: destination) }
                if movedTrust { try fileManager.moveItem(at: trustBackup, to: recordURL) }
                try fileManager.removeItem(at: transaction)
            } catch {
                // 恢复失败时保留备份供人工恢复，不能在 defer 中丢弃最后一份旧内容。
                preserveBackup = true
                Self.logger.error("插件安装回滚失败，备份保留于 \(transaction.path)：\(error.localizedDescription)。")
                throw error
            }
            throw error
        }
        try? fileManager.removeItem(at: transaction)
        Self.logger.info("已安装受管插件：\(candidate.manifest.id)。")
        return destination
    }

    /// 只删除 Leap 自己创建的受管副本和对应信任记录，不接触用户选择的源目录。
    public func uninstall(pluginID: String, fileManager: FileManager = .default) throws {
        guard !AppPaths.isOfficialPluginID(pluginID) else { throw InstallationError.officialPluginReserved }
        let destination = try paths.managedPluginDirectory(for: pluginID)
        guard destination.deletingLastPathComponent().standardizedFileURL == paths.pluginsDirectory.standardizedFileURL else {
            throw InstallationError.managedDirectoryEscape
        }

        let recordURL = try paths.trustRecordURL(for: pluginID)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if fileManager.fileExists(atPath: recordURL.path) {
            try fileManager.removeItem(at: recordURL)
        }
        Self.logger.info("已卸载受管插件：\(pluginID)。")
    }

    public func readTrustRecord(for pluginID: String, fileManager: FileManager = .default) throws -> PluginTrustRecord? {
        let recordURL = try paths.trustRecordURL(for: pluginID)
        guard fileManager.fileExists(atPath: recordURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(PluginTrustRecord.self, from: Data(contentsOf: recordURL))
    }

    public func contentDigest(of directory: URL, version: Int = 2, fileManager: FileManager = .default) throws -> String {
        guard version == 1 || version == 2 else { throw InstallationError.unsupportedDigest }
        if version == 2, try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw RemotePluginError.unsupportedFile
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: version == 1 ? [.skipsHiddenFiles] : [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if version == 2, values.isSymbolicLink == true || (values.isRegularFile != true && values.isDirectory != true) {
                throw RemotePluginError.unsupportedFile
            }
            if values.isRegularFile == true { files.append(file) }
        }
        if let enumerationError { throw enumerationError }
        files.sort { $0.path < $1.path }

        var digest = SHA256()
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for file in files {
            // Foundation 枚举会将 /var 解析为 /private/var，摘要必须与暂存目录位置无关。
            let relativePath: String
            if version == 1 {
                relativePath = file.path.replacingOccurrences(of: directory.standardizedFileURL.path + "/", with: "")
            } else {
                let canonicalPath = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonicalPath.hasPrefix(rootPath) else { throw InstallationError.managedDirectoryEscape }
                relativePath = String(canonicalPath.dropFirst(rootPath.count))
            }
            digest.update(data: Data(relativePath.utf8))
            if version == 2 {
                // 文件长度参与分帧，防止文件内容与下一条路径拼接出相同的摘要输入。
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                digest.update(data: Data("\u{0}\(size)\u{0}".utf8))
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                digest.update(data: data)
            }
            if version == 2 { digest.update(data: Data([0])) }
        }
        return digest.finalize().hexadecimalRepresentation
    }
}

private extension SHA256.Digest {
    var hexadecimalRepresentation: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
