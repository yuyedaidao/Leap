import Foundation
@preconcurrency import YQLogger

public enum PluginStoreError: LocalizedError, Equatable {
    case invalidIndex
    case unsupportedSchema
    case noCache
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalidIndex: "插件商店索引不可用，请稍后重试。"
        case .notFound: "无法获取插件商店索引，请检查商店仓库是否公开或索引文件是否存在。"
        case .unsupportedSchema: "插件商店索引版本不受支持，请更新 Leap。"
        case .noCache: "尚未获取过插件商店索引。"
        }
    }
}

/// 官方商店来源：v1 只有一个，读取层按 owner/repo/ref 参数化，后续加 tap 无需改动解析。
public struct PluginStoreSource: Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let reference: String

    public static let official = PluginStoreSource(owner: "yuyedaidao", repository: "LeapPlugins", reference: "main")

    public init(owner: String, repository: String, reference: String) {
        self.owner = owner
        self.repository = repository
        self.reference = reference
    }

    /// 索引直接走 raw 地址，不占用 GitHub API 的匿名限额。
    public var indexURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(reference)/store.json")!
    }
}

public struct PluginStoreEntry: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String?
    public let path: String
    public let runtime: String?
    public let minimumHostVersion: String?
    public let commands: [String]

    public init(
        id: String, name: String, version: String, summary: String? = nil, path: String,
        runtime: String? = nil, minimumHostVersion: String? = nil, commands: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.path = path
        self.runtime = runtime
        self.minimumHostVersion = minimumHostVersion
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, summary, path, runtime, minimumHostVersion, commands
    }

    /// `commands` 缺省视为没有命令标题，不让单个可选字段让整份索引解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        path = try container.decode(String.self, forKey: .path)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        minimumHostVersion = try container.decodeIfPresent(String.self, forKey: .minimumHostVersion)
        commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        case updatable
    }

    /// 只有更高版本才算可更新；同版本内容变化不在商店里表达。
    public func state(installedVersion: String?) -> State {
        guard let installedVersion else { return .notInstalled }
        return version.compare(installedVersion, options: .numeric) == .orderedDescending ? .updatable : .installed
    }

    /// 与清单校验同一规则：三段数字且不高于宿主版本；缺省视为不限制。
    public func isCompatibleWithHost() -> Bool {
        guard let minimumHostVersion else { return true }
        let components = minimumHostVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
            components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return false }
        return minimumHostVersion.compare(PluginManifest.hostVersion, options: .numeric) != .orderedDescending
    }

    public func installAddress(source: PluginStoreSource) -> String {
        "https://github.com/\(source.owner)/\(source.repository)/tree/\(source.reference)/\(path)"
    }
}

public struct PluginStoreIndex: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    static let maximumEntries = 500
    static let maximumIndexBytes = 4 * 1_024 * 1_024

    private static let logger = YQLogger(label: "com.padding.leap/plugin-store")

    public let schemaVersion: Int
    public let name: String?
    public let plugins: [PluginStoreEntry]

    public init(
        schemaVersion: Int = PluginStoreIndex.supportedSchemaVersion, name: String? = nil,
        plugins: [PluginStoreEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.plugins = plugins
    }

    /// 单条不合格只跳过该条，避免一个坏条目让整份索引不可用。
    public static func decode(_ data: Data) throws -> PluginStoreIndex {
        guard data.count <= maximumIndexBytes else { throw PluginStoreError.invalidIndex }
        struct Raw: Decodable {
            let schemaVersion: Int
            let name: String?
            let plugins: [PluginStoreEntry]
        }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw PluginStoreError.invalidIndex }
        guard raw.schemaVersion == supportedSchemaVersion else { throw PluginStoreError.unsupportedSchema }

        var identifiers = Set<String>()
        let entries = raw.plugins.filter { entry in
            guard entry.isValidEntry, !AppPaths.isOfficialPluginID(entry.id), !identifiers.contains(entry.id) else {
                logger.warning("跳过无效商店条目：\(entry.id)。")
                return false
            }
            identifiers.insert(entry.id)
            return true
        }
        return PluginStoreIndex(
            schemaVersion: raw.schemaVersion, name: raw.name, plugins: Array(entries.prefix(maximumEntries)))
    }

    public func entry(id: String) -> PluginStoreEntry? {
        plugins.first { $0.id == id }
    }
}

extension PluginStoreEntry {
    /// 目录必须是可以安全拼进安装地址的相对路径。
    fileprivate var isValidEntry: Bool {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty, !trimmedVersion.isEmpty else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            })
        else { return false }
        return true
    }
}
