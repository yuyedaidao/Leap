import Foundation

public struct PluginManifest: Codable, Equatable, Sendable {
    /// 版本单一来源是 Project.swift 的 CFBundleShortVersionString；测试进程没有 app Info.plist 时回退。
    public static let hostVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    /// 单位为逻辑点：独立窗口为网页内容尺寸，内嵌高度包含宿主操作栏；均不含系统标题栏。
    public struct WebWindow: Codable, Equatable, Sendable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public enum Runtime: String, Codable, CaseIterable, Sendable {
        case python
        case javascript
        case shell
    }

    public struct Command: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case action, interactive }
        public enum Presentation: String, Codable, Sendable { case list, web }

        public struct Input: Codable, Equatable, Sendable {
            public let enabled: Bool?
            public let placeholder: String?
            public init(enabled: Bool? = nil, placeholder: String? = nil) {
                self.enabled = enabled
                self.placeholder = placeholder
            }
        }

        public struct Match: Codable, Equatable, Sendable {
            public enum Kind: String, Codable, Sendable { case text, regex }
            public let type: Kind
            public let pattern: String?
            public let minLength: Int?
            public let maxLength: Int?
            public init(type: Kind, pattern: String? = nil, minLength: Int? = nil, maxLength: Int? = nil) {
                self.type = type
                self.pattern = pattern
                self.minLength = minLength
                self.maxLength = maxLength
            }
        }

        public enum ExecutionMode: String, Codable, Sendable {
            case foreground
            case background
        }

        public let id: String
        public let title: String
        public let executionMode: ExecutionMode?
        public let mode: Mode?
        public let presentation: Presentation?
        public let keywords: [String]?
        public let input: Input?
        public let matches: [Match]?
        public var inputEnabled: Bool { input?.enabled ?? true }

        /// 旧插件清单未声明执行模式时，保持原有的等待执行行为。
        public var resolvedExecutionMode: ExecutionMode { executionMode ?? .foreground }

        public init(
            id: String, title: String, executionMode: ExecutionMode? = nil,
            mode: Mode? = nil, presentation: Presentation? = nil, keywords: [String]? = nil,
            input: Input? = nil, matches: [Match]? = nil
        ) {
            self.id = id
            self.title = title
            self.executionMode = executionMode
            self.mode = mode
            self.presentation = presentation
            self.keywords = keywords
            self.input = input
            self.matches = matches
        }
    }

    public let id: String
    public let name: String
    public let version: String
    public let runtime: Runtime
    public let entry: String
    public let commands: [Command]
    public let webEntry: String?
    public let webWindow: WebWindow?
    public let icon: String?
    public let minimumHostVersion: String?

    public init(
        id: String,
        name: String,
        version: String,
        runtime: Runtime,
        entry: String,
        commands: [Command],
        webEntry: String? = nil,
        icon: String? = nil,
        webWindow: WebWindow? = nil,
        minimumHostVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.runtime = runtime
        self.entry = entry
        self.commands = commands
        self.webEntry = webEntry
        self.icon = icon
        self.webWindow = webWindow
        self.minimumHostVersion = minimumHostVersion
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
        case invalidWebWindow
        case invalidInteraction
        case invalidMatch
        case unsupportedHostVersion

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
            case .invalidWebWindow: "网页窗口尺寸必须至少为 400 × 300，且需要声明网页入口。"
            case .invalidInteraction: "命令交互配置无效：列表需启用输入，网页需入口，Shell 不支持交互模式。"
            case .invalidMatch: "命令关键词或文本匹配规则无效。"
            case .unsupportedHostVersion: "插件要求的 Leap 版本无效或高于当前版本。"
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

        try validateOptionalResources(manifest, in: pluginDirectory, fileManager: fileManager)
        try validateInteraction(manifest)
    }

    private func validateInteraction(_ manifest: PluginManifest) throws {
        if let version = manifest.minimumHostVersion {
            let components = version.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  version.compare(PluginManifest.hostVersion, options: .numeric) != .orderedDescending else {
                throw ValidationError.unsupportedHostVersion
            }
        }
        for command in manifest.commands {
            switch command.mode {
            case .action, nil:
                guard command.presentation == nil, command.input == nil else { throw ValidationError.invalidInteraction }
            case .interactive:
                guard manifest.runtime != .shell, let presentation = command.presentation,
                      command.resolvedExecutionMode != .background,
                      !command.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      presentation != .web || manifest.webEntry != nil,
                      presentation != .list || command.inputEnabled else { throw ValidationError.invalidInteraction }
            }
            guard command.keywords?.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else {
                throw ValidationError.invalidMatch
            }
            for match in command.matches ?? [] {
                let minimum = match.minLength ?? 1
                let maximum = match.maxLength ?? 1000
                guard minimum >= 1, maximum >= minimum, maximum <= 10_000 else { throw ValidationError.invalidMatch }
                switch match.type {
                case .text:
                    guard match.pattern == nil else { throw ValidationError.invalidMatch }
                case .regex:
                    guard let pattern = match.pattern, !pattern.isEmpty, pattern.count <= 1000,
                          (try? NSRegularExpression(pattern: pattern)) != nil else { throw ValidationError.invalidMatch }
                }
            }
        }
    }

    private func validateOptionalResources(
        _ manifest: PluginManifest,
        in pluginDirectory: URL,
        fileManager: FileManager
    ) throws {
        if let icon = manifest.icon {
            let iconExtension = URL(fileURLWithPath: icon).pathExtension.lowercased()
            guard isSafeRelativePath(icon), ["png", "jpg", "jpeg", "icns"].contains(iconExtension) else {
                throw ValidationError.invalidIcon
            }
            guard fileManager.fileExists(atPath: pluginDirectory.appendingPathComponent(icon).path) else {
                throw ValidationError.missingIcon
            }
        }

        if let size = manifest.webWindow {
            guard manifest.webEntry != nil, size.width >= 400, size.height >= 300 else {
                throw ValidationError.invalidWebWindow
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
