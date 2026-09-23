import Foundation
@preconcurrency import YQLogger

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

/// 设置页按插件管理受信任的受管副本，启动器仍按命令索引它们。
public struct InstalledPluginDescriptor: Identifiable, Equatable, Sendable {
    public let manifest: PluginManifest
    public let pluginDirectory: URL
    public let iconURL: URL?

    public var id: String { manifest.id }

    public init(manifest: PluginManifest, pluginDirectory: URL, iconURL: URL?) {
        self.manifest = manifest
        self.pluginDirectory = pluginDirectory
        self.iconURL = iconURL
    }
}

public struct InstalledPluginCatalog {
    private static let logger = YQLogger(label: "com.padding.leap/plugin-catalog")

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// 仅返回仍与信任记录匹配的受管副本，手工篡改的目录不会进入搜索结果。
    public func loadPlugins(fileManager: FileManager = .default) -> [InstalledPluginDescriptor] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: paths.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let installer = PluginInstaller(paths: paths)
        let validator = PluginManifestValidator()
        return directories.compactMap { directory -> InstalledPluginDescriptor? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            do {
                let manifest = try validator.load(from: directory)
                let contentDigest = try installer.contentDigest(of: directory)
                guard directory.lastPathComponent == manifest.id,
                      let record = try installer.readTrustRecord(for: manifest.id),
                      record.version == manifest.version,
                      record.contentDigest == contentDigest else {
                    return nil
                }
                let iconURL = manifest.icon.map { directory.appendingPathComponent($0) }
                return InstalledPluginDescriptor(manifest: manifest, pluginDirectory: directory, iconURL: iconURL)
            } catch {
                Self.logger.warning("跳过无效受管插件：\(directory.lastPathComponent)，原因：\(error.localizedDescription)。")
                return nil
            }
        }
        .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    /// 启动器保留按命令搜索和排序的既有行为。
    public func load(fileManager: FileManager = .default) -> [PluginCommandDescriptor] {
        loadPlugins(fileManager: fileManager)
            .flatMap { plugin in
                plugin.manifest.commands.map {
                    PluginCommandDescriptor(
                        pluginID: plugin.manifest.id,
                        pluginName: plugin.manifest.name,
                        commandID: $0.id,
                        title: $0.title,
                        manifest: plugin.manifest,
                        pluginDirectory: plugin.pluginDirectory,
                        iconURL: plugin.iconURL
                    )
                }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
