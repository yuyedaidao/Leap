import Foundation
@preconcurrency import YQLogger

public struct AppPaths: Sendable {
    public enum PathError: LocalizedError, Equatable {
        case missingResourceDirectory
        case invalidPluginIdentifier

        public var errorDescription: String? {
            switch self {
            case .missingResourceDirectory:
                "Leap 的资源目录不可用。"
            case .invalidPluginIdentifier:
                "插件标识符包含不允许的路径字符。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/paths")

    public let applicationSupportDirectory: URL
    public let resourceDirectory: URL

    public init(applicationSupportDirectory: URL, resourceDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.resourceDirectory = resourceDirectory.standardizedFileURL
    }

    public init(bundle: Bundle = .main, fileManager: FileManager = .default) throws {
        guard let resourceDirectory = bundle.resourceURL else {
            throw PathError.missingResourceDirectory
        }

        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        self.init(
            applicationSupportDirectory: supportDirectory.appendingPathComponent("Leap", isDirectory: true),
            resourceDirectory: resourceDirectory
        )
    }

    public var pluginsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    /// 官方插件直接读取随包资源，不创建可被本地安装覆盖的受管副本。
    public static let templateGeneratorID = "com.padding.leap.template-generator"
    public static let clipboardPluginID = "com.padding.leap.clipboard"
    private static let officialPluginIDs: Set<String> = [templateGeneratorID, clipboardPluginID]

    public var officialPluginsDirectory: URL {
        resourceDirectory.appendingPathComponent("OfficialPlugins", isDirectory: true)
    }

    public static func isOfficialPluginID(_ id: String) -> Bool {
        officialPluginIDs.contains(id)
    }

    public func pluginDatabaseDirectory(for pluginIdentifier: String) throws -> URL {
        guard Self.isSafePluginIdentifier(pluginIdentifier) else { throw PathError.invalidPluginIdentifier }
        return applicationSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginIdentifier, isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
    }

    public var clipboardHistoryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    public var trustRecordsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Trust", isDirectory: true)
    }

    public var runtimesDirectory: URL {
        resourceDirectory.appendingPathComponent("Runtimes", isDirectory: true)
    }

    public var applicationIndexCacheURL: URL {
        applicationSupportDirectory.appendingPathComponent("application-index-v1.json")
    }

    public func managedPluginDirectory(for pluginIdentifier: String) throws -> URL {
        guard Self.isSafePluginIdentifier(pluginIdentifier) else {
            throw PathError.invalidPluginIdentifier
        }
        return pluginsDirectory.appendingPathComponent(pluginIdentifier, isDirectory: true)
    }

    public func trustRecordURL(for pluginIdentifier: String) throws -> URL {
        guard Self.isSafePluginIdentifier(pluginIdentifier) else {
            throw PathError.invalidPluginIdentifier
        }
        return trustRecordsDirectory.appendingPathComponent("\(pluginIdentifier).json")
    }

    public func createManagedDirectories(fileManager: FileManager = .default) throws {
        for directory in [applicationSupportDirectory, pluginsDirectory, trustRecordsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        Self.logger.debug("已确保 Leap 的受管数据目录存在。")
    }

    private static func isSafePluginIdentifier(_ value: String) -> Bool {
        !value.isEmpty &&
            value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" } &&
            !value.contains("..")
    }
}
