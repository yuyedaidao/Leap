import Foundation
import OSLog

public struct PluginCommandDescriptor: Identifiable, Equatable, Sendable {
    public let pluginID: String
    public let pluginName: String
    public let commandID: String
    public let title: String
    public let manifest: PluginManifest
    public let pluginDirectory: URL
    public let iconURL: URL?

    public var id: String { "\(pluginID)/\(commandID)" }

    public init(
        pluginID: String,
        pluginName: String,
        commandID: String,
        title: String,
        manifest: PluginManifest,
        pluginDirectory: URL,
        iconURL: URL?
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.commandID = commandID
        self.title = title
        self.manifest = manifest
        self.pluginDirectory = pluginDirectory
        self.iconURL = iconURL
    }
}

public struct InstalledPluginCatalog {
    private static let logger = Logger(subsystem: "com.padding.leap", category: "plugin-catalog")

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// 仅返回仍与信任记录匹配的受管副本，手工篡改的目录不会进入搜索结果。
    public func load(fileManager: FileManager = .default) -> [PluginCommandDescriptor] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: paths.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let installer = PluginInstaller(paths: paths)
        let validator = PluginManifestValidator()
        return directories.flatMap { directory -> [PluginCommandDescriptor] in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }
            do {
                let manifest = try validator.load(from: directory)
                let contentDigest = try installer.contentDigest(of: directory)
                guard directory.lastPathComponent == manifest.id,
                      let record = try installer.readTrustRecord(for: manifest.id),
                      record.version == manifest.version,
                      record.contentDigest == contentDigest else {
                    return []
                }
                let iconURL = manifest.icon.map { directory.appendingPathComponent($0) }
                return manifest.commands.map {
                    PluginCommandDescriptor(
                        pluginID: manifest.id,
                        pluginName: manifest.name,
                        commandID: $0.id,
                        title: $0.title,
                        manifest: manifest,
                        pluginDirectory: directory,
                        iconURL: iconURL
                    )
                }
            } catch {
                Self.logger.warning("跳过无效受管插件：\(directory.lastPathComponent, privacy: .public)，原因：\(error.localizedDescription, privacy: .public)。")
                return []
            }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
