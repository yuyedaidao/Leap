import Foundation

/// 每个插件独占一个文档目录；同一目录的所有实例通过进程内共享队列串行访问。
public final class PluginDocumentStore: @unchecked Sendable {
    public enum StoreError: LocalizedError, Equatable {
        case invalidDocument
        case invalidIdentifier
        case documentTooLarge
        case conflict
        case missingDocument

        public var errorDescription: String? {
            switch self {
            case .invalidDocument: "数据库文档必须包含有效的 _id。"
            case .invalidIdentifier: "数据库文档 _id 包含不允许的路径字符。"
            case .documentTooLarge: "单个数据库文档不能超过 1MB。"
            case .conflict: "数据库文档版本已变化，请重新读取后更新。"
            case .missingDocument: "数据库文档不存在。"
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.padding.leap/plugin-document-store")
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func put(_ document: PluginValue) throws -> PluginValue {
        try Self.queue.sync {
            guard case var .object(fields) = document,
                  let id = fields["_id"]?.string, !id.isEmpty else { throw StoreError.invalidDocument }
            guard Self.isSafeIdentifier(id) else { throw StoreError.invalidIdentifier }
            let url = documentURL(id)
            let existing = try read(url)
            let revision = fields["_rev"]?.string
            if let existing {
                guard revision != nil, revision == existing["_rev"]?.string else { throw StoreError.conflict }
            } else if revision != nil { throw StoreError.conflict }
            let nextRevision = UUID().uuidString
            fields["_rev"] = .string(nextRevision)
            let updated = PluginValue.object(fields)
            let data = try encoded(updated)
            guard data.count <= 1024 * 1024 else { throw StoreError.documentTooLarge }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .object(["id": .string(id), "rev": .string(nextRevision), "ok": .bool(true)])
        }
    }

    public func get(_ id: String) throws -> PluginValue? {
        try Self.queue.sync {
            guard Self.isSafeIdentifier(id) else { throw StoreError.invalidIdentifier }
            return try read(documentURL(id))
        }
    }

    public func remove(_ id: String, revision: String) throws -> PluginValue {
        try Self.queue.sync {
            guard Self.isSafeIdentifier(id) else { throw StoreError.invalidIdentifier }
            let url = documentURL(id)
            guard let existing = try read(url) else { throw StoreError.missingDocument }
            guard existing["_rev"]?.string == revision else { throw StoreError.conflict }
            try fileManager.removeItem(at: url)
            return .object(["id": .string(id), "ok": .bool(true)])
        }
    }

    public func allDocs() throws -> [PluginValue] {
        try Self.queue.sync {
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            let urls = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return try urls.filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { try read($0) }
        }
    }

    private func documentURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func read(_ url: URL) throws -> PluginValue? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PluginValue.self, from: Data(contentsOf: url))
    }

    private func encoded(_ document: PluginValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty &&
            value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" } &&
            !value.contains("..")
    }
}

/// 宿主监听与插件进程共用存储实例，避免同插件并发写入时绕出版本校验。
public final class PluginDocumentStoreProvider: @unchecked Sendable {
    private let paths: AppPaths
    private let lock = NSLock()
    private var stores: [String: PluginDocumentStore] = [:]

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func store(for pluginID: String) throws -> PluginDocumentStore {
        try lock.withLock {
            if let store = stores[pluginID] { return store }
            let store = PluginDocumentStore(directory: try paths.pluginDatabaseDirectory(for: pluginID))
            stores[pluginID] = store
            return store
        }
    }
}
