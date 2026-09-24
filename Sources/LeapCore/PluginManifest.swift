import Foundation

public struct PluginManifest: Codable, Equatable, Sendable {
    public enum Runtime: String, Codable, CaseIterable, Sendable {
        case python
        case javascript
        case shell
    }

    public struct Command: Codable, Equatable, Sendable {
        public enum ExecutionMode: String, Codable, Sendable {
            case foreground
            case background
        }

        public let id: String
        public let title: String
        public let executionMode: ExecutionMode?

        /// 旧插件清单未声明执行模式时，保持原有的等待执行行为。
        public var resolvedExecutionMode: ExecutionMode { executionMode ?? .foreground }

        public init(id: String, title: String, executionMode: ExecutionMode? = nil) {
            self.id = id
            self.title = title
            self.executionMode = executionMode
        }
    }

    public let id: String
    public let name: String
    public let version: String
    public let runtime: Runtime
    public let entry: String
    public let commands: [Command]
    public let webEntry: String?
    public let icon: String?

    public init(
        id: String,
        name: String,
        version: String,
        runtime: Runtime,
        entry: String,
        commands: [Command],
        webEntry: String? = nil,
        icon: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.runtime = runtime
        self.entry = entry
        self.commands = commands
        self.webEntry = webEntry
        self.icon = icon
    }
}

public struct PluginManifestValidator {
    public enum ValidationError: LocalizedError, Equatable {
        case missingManifest
        case malformedManifest
        case emptyPluginID
        case duplicatePluginID
        case emptyName
        case emptyVersion
        case invalidEntry
        case missingEntry
        case missingCommands
        case duplicateCommandID
        case invalidIcon
        case missingIcon
        case invalidWebEntry
        case missingWebEntry

        public var errorDescription: String? {
            switch self {
            case .missingManifest: "插件目录缺少 manifest.json。"
            case .malformedManifest: "manifest.json 格式无效或缺少必填字段。"
            case .emptyPluginID: "插件 ID 不能为空。"
            case .duplicatePluginID: "插件 ID 已存在。"
            case .emptyName: "插件名称不能为空。"
            case .emptyVersion: "插件版本不能为空。"
            case .invalidEntry: "插件入口必须是目录内的相对路径。"
            case .missingEntry: "插件入口文件不存在。"
            case .missingCommands: "插件至少需要声明一个命令。"
            case .duplicateCommandID: "插件命令 ID 不能重复。"
            case .invalidIcon: "插件图标必须是目录内的 PNG、JPEG 或 ICNS 文件。"
            case .missingIcon: "插件声明的图标文件不存在。"
            case .invalidWebEntry: "网页入口必须是目录内的相对路径。"
            case .missingWebEntry: "插件声明的网页入口文件不存在。"
            }
        }
    }

    public init() {}

    public func load(
        from pluginDirectory: URL,
        installedPluginIDs: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> PluginManifest {
        let manifestURL = pluginDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ValidationError.missingManifest
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ValidationError.malformedManifest
        }

        try validate(manifest, in: pluginDirectory, installedPluginIDs: installedPluginIDs, fileManager: fileManager)
        return manifest
    }

    public func validate(
        _ manifest: PluginManifest,
        in pluginDirectory: URL,
        installedPluginIDs: Set<String> = [],
        fileManager: FileManager = .default
    ) throws {
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyPluginID
        }
        guard !installedPluginIDs.contains(manifest.id) else {
            throw ValidationError.duplicatePluginID
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyName
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyVersion
        }
        guard isSafeRelativePath(manifest.entry) else {
            throw ValidationError.invalidEntry
        }

        let entryURL = pluginDirectory.appendingPathComponent(manifest.entry).standardizedFileURL
        guard entryURL.path.hasPrefix(pluginDirectory.standardizedFileURL.path + "/") else {
            throw ValidationError.invalidEntry
        }
        guard fileManager.fileExists(atPath: entryURL.path) else {
            throw ValidationError.missingEntry
        }
        guard !manifest.commands.isEmpty else {
            throw ValidationError.missingCommands
        }
        guard Set(manifest.commands.map(\.id)).count == manifest.commands.count else {
            throw ValidationError.duplicateCommandID
        }

        if let icon = manifest.icon {
            let iconExtension = URL(fileURLWithPath: icon).pathExtension.lowercased()
            guard isSafeRelativePath(icon), ["png", "jpg", "jpeg", "icns"].contains(iconExtension) else {
                throw ValidationError.invalidIcon
            }
            guard fileManager.fileExists(atPath: pluginDirectory.appendingPathComponent(icon).path) else {
                throw ValidationError.missingIcon
            }
        }

        if let webEntry = manifest.webEntry {
            guard manifest.runtime != .shell else {
                throw ValidationError.invalidWebEntry
            }
            guard isSafeRelativePath(webEntry) else {
                throw ValidationError.invalidWebEntry
            }
            guard fileManager.fileExists(atPath: pluginDirectory.appendingPathComponent(webEntry).path) else {
                throw ValidationError.missingWebEntry
            }
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
