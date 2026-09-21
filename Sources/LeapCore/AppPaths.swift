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
