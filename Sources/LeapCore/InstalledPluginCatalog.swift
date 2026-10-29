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

/// 设置页按来源管理官方插件与受信任副本，启动器按命令索引。
public struct InstalledPluginDescriptor: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable { case official, local }

    public let origin: Origin
    public let manifest: PluginManifest
    public let pluginDirectory: URL
    public let iconURL: URL?

    public var id: String { manifest.id }

    public init(manifest: PluginManifest, pluginDirectory: URL, iconURL: URL?, origin: Origin = .local) {
        self.origin = origin
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

    /// 官方插件来自随包目录；本地插件仅返回与信任记录匹配的受管副本。
    public func loadPlugins(fileManager: FileManager = .default) -> [InstalledPluginDescriptor] {
        let official = loadOfficialPlugins(fileManager: fileManager)
        let directories = (try? fileManager.contentsOfDirectory(
            at: paths.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let installer = PluginInstaller(paths: paths)
        let validator = PluginManifestValidator()
        let local = directories.compactMap { directory -> InstalledPluginDescriptor? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            do {
                let manifest = try validator.load(from: directory)
                // 保留旧受管副本，但永远不让同 ID 本地内容冒充官方插件。
                guard !AppPaths.isOfficialPluginID(manifest.id) else { return nil }
                guard directory.lastPathComponent == manifest.id,
                      let record = try installer.readTrustRecord(for: manifest.id),
                      record.version == manifest.version,
                      record.contentDigest == (try installer.contentDigest(
                        of: directory, version: record.digestVersion ?? 1
                      )) else {
                    return nil
                }
                let iconURL = manifest.icon.map { directory.appendingPathComponent($0) }
                return InstalledPluginDescriptor(manifest: manifest, pluginDirectory: directory, iconURL: iconURL)
            } catch {
                Self.logger.warning("跳过无效受管插件：\(directory.lastPathComponent)，原因：\(error.localizedDescription)。")
                return nil
            }
        }
        return (official + local)
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    private func loadOfficialPlugins(fileManager: FileManager) -> [InstalledPluginDescriptor] {
        // 官方资源缺失只影响官方插件，不阻止本地插件索引。
        guard fileManager.fileExists(atPath: paths.officialPluginsDirectory.path) else {
            Self.logger.error("官方插件资源目录不存在。")
            return []
        }
        let directories = (try? fileManager.contentsOfDirectory(
            at: paths.officialPluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var identifiers = Set<String>()
        return directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            do {
                let manifest = try PluginManifestValidator().load(
                    from: directory, installedPluginIDs: identifiers, fileManager: fileManager
                )
                guard AppPaths.isOfficialPluginID(manifest.id) else {
                    throw PluginManifestValidator.ValidationError.malformedManifest
                }
                identifiers.insert(manifest.id)
                return InstalledPluginDescriptor(
                    manifest: manifest, pluginDirectory: directory,
                    iconURL: manifest.icon.map { directory.appendingPathComponent($0) }, origin: .official
                )
            } catch {
                Self.logger.error("官方插件资源不可用：\(directory.lastPathComponent)，\(error.localizedDescription)。")
                return nil
            }
        }
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
