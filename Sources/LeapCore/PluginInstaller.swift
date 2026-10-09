import CryptoKit
import Foundation
@preconcurrency import YQLogger

public struct PluginTrustRecord: Codable, Equatable, Sendable {
    public let pluginID: String
    public let version: String
    public let contentDigest: String
}

public struct PluginInstallCandidate: Equatable, Sendable {
    public let sourceDirectory: URL
    public let manifest: PluginManifest
    public let contentDigest: String
}

public struct PluginInstaller {
    public enum InstallationError: LocalizedError {
        case officialPluginReserved
        case confirmationRequired
        case managedDirectoryEscape

        public var errorDescription: String? {
            switch self {
            case .officialPluginReserved: "官方内置插件随 Leap 更新，不能本地覆盖或卸载。"
            case .confirmationRequired: "插件内容尚未获得确认。"
            case .managedDirectoryEscape: "受管插件目录不安全。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/plugin-installer")

    public let paths: AppPaths
    private let manifestValidator = PluginManifestValidator()

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func inspect(sourceDirectory: URL, fileManager: FileManager = .default) throws -> PluginInstallCandidate {
        let manifest = try manifestValidator.load(from: sourceDirectory, fileManager: fileManager)
        guard !AppPaths.isOfficialPluginID(manifest.id) else { throw InstallationError.officialPluginReserved }
        return PluginInstallCandidate(
            sourceDirectory: sourceDirectory.standardizedFileURL,
            manifest: manifest,
            contentDigest: try contentDigest(of: sourceDirectory, fileManager: fileManager)
        )
    }

    public func requiresConfirmation(
        for candidate: PluginInstallCandidate,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let record = try? readTrustRecord(for: candidate.manifest.id, fileManager: fileManager) else {
            return true
        }
        return record.version != candidate.manifest.version || record.contentDigest != candidate.contentDigest
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

        let stagingDirectory = paths.pluginsDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        try fileManager.copyItem(at: candidate.sourceDirectory, to: stagingDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagingDirectory, to: destination)

        let record = PluginTrustRecord(
            pluginID: candidate.manifest.id,
            version: candidate.manifest.version,
            contentDigest: candidate.contentDigest
        )
        let recordURL = try paths.trustRecordURL(for: candidate.manifest.id)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
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

    public func contentDigest(of directory: URL, fileManager: FileManager = .default) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SHA256.hash(data: Data()).hexadecimalRepresentation
        }

        let files = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }

        var digest = SHA256()
        for file in files {
            let relativePath = file.path.replacingOccurrences(of: directory.standardizedFileURL.path + "/", with: "")
            digest.update(data: Data(relativePath.utf8))
            digest.update(data: try Data(contentsOf: file))
        }
        return digest.finalize().hexadecimalRepresentation
    }
}

private extension SHA256.Digest {
    var hexadecimalRepresentation: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
