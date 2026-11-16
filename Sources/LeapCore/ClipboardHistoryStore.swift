import CryptoKit
import Foundation
import YQLogger

/// 单条剪切板历史；数据归宿主所有，插件只通过宿主接口读取。
public struct ClipboardRecord: Equatable, Sendable {
    public let id: String
    public let type: String
    public let timestamp: Int64
    public let hash: String
    /// 所属分组目录名，用于重写和淘汰。
    public let group: String
    public let text: String?
    public let files: [String]?
    public let imagePath: String?

    public var pluginValue: PluginValue {
        var fields: [String: PluginValue] = [
            "id": .string(id), "type": .string(type),
            "timestamp": .number(Double(timestamp)), "hash": .string(hash)
        ]
        if let text { fields["text"] = .string(text) }
        if let files { fields["files"] = .array(files.map(PluginValue.string)) }
        if let imagePath { fields["imagePath"] = .string(imagePath) }
        return .object(fields)
    }

    /// 搜索覆盖标题与正文；图片按固定关键词可搜，与旧插件行为一致。
    var searchable: String {
        switch type {
        case "text": return (text ?? "").lowercased()
        case "files":
            let values = files ?? []
            let names = values.map { URL(fileURLWithPath: $0).lastPathComponent }
            return (names + values).joined(separator: "\n").lowercased()
        default: return "图片 image"
        }
    }
}

/// 照搬 uTools 的分组追加日志：`<目录>/<13 位毫秒组名>/data` 每行一条 JSON，
/// 每组最多 100 条，图片与该组 data 同目录；读取只解析最近的若干组。
@MainActor
public final class ClipboardHistoryStore {
    public static let defaultMaximumRecords = 1000
    public static let defaultGroupSize = 100
    /// 单条文本上限，防止一次复制把日志拖成几十 MB。
    public static let maximumTextLength = 200_000
    private static let logger = YQLogger(label: "com.padding.leap/clipboard-store")

    private struct Stored: Codable {
        var id: String
        var type: String
        var timestamp: Int64
        var hash: String
        var text: String?
        var files: [String]?
        /// 组内图片文件名，读取时再拼成绝对路径。
        var imagePath: String?
    }

    /// 新到旧，插件与宿主共用这一份内存快照。
    public private(set) var records: [ClipboardRecord] = []
    /// 新记录写入后回调，用于通知已打开的插件列表。
    public var onAppend: ((ClipboardRecord) -> Void)?
    public let directory: URL
    private let maximumRecords: Int
    private let groupSize: Int
    private let fileManager: FileManager
    private var currentGroup: String?
    private var currentGroupCount = 0

    public init(directory: URL, maximumRecords: Int = defaultMaximumRecords,
                groupSize: Int = defaultGroupSize, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.maximumRecords = max(1, maximumRecords)
        self.groupSize = max(1, groupSize)
        self.fileManager = fileManager
        reload()
    }

    /// 多留一组：当前组写满后新组才能接上，读取窗口与 uTools 一致。
    private var maximumGroups: Int { maximumRecords / groupSize + 1 }

    public func reload() {
        do {
            try load()
        } catch {
            records = []
            currentGroup = nil
            currentGroupCount = 0
            Self.logger.error("读取剪切板历史失败：\(error.localizedDescription)")
        }
    }

    /// 写入一条记录；与最新一条内容相同或内容为空时不追加，返回 nil。
    @discardableResult
    public func append(type: String, text: String? = nil, files: [String]? = nil, image: Data? = nil,
                       timestamp: Int64? = nil) throws -> ClipboardRecord? {
        if let text, text.utf8.count > Self.maximumTextLength { return nil }
        guard let hash = contentHash(text: text, files: files, image: image) else { return nil }
        // 反复复制同一段内容只保留最新一条。
        if records.first?.hash == hash { return nil }

        let time = timestamp ?? Int64((Date().timeIntervalSince1970 * 1000).rounded())
        var id = String(time)
        while records.contains(where: { $0.id == id }) { id = String((Int64(id) ?? time) + 1) }

        let group = try writableGroup(at: time)
        var stored = Stored(id: id, type: type, timestamp: time, hash: hash, text: text, files: files, imagePath: nil)
        // 先落图片再写日志行，避免日志指向尚不存在的文件。
        if let image {
            let name = "\(hash).png"
            try image.write(to: groupURL(group).appendingPathComponent(name), options: .atomic)
            stored.imagePath = name
        }
        try appendLine(stored, to: group)
        currentGroupCount += 1
        let record = record(stored, in: group)
        records.insert(record, at: 0)
        // 同一内容只保留最新一条；旧行留在组文件里，由读取时的 hash 去重跳过。
        records.removeAll { $0.hash == hash && $0.id != id }
        try trimOverflow()
        onAppend?(record)
        return record
    }

    /// 去重依据：图片用原始字节，文件列表用编码后的数组，文本用 UTF-8。
    private func contentHash(text: String?, files: [String]?, image: Data?) -> String? {
        let digest: Data
        if let image, !image.isEmpty { digest = image } else if let files, !files.isEmpty {
            guard let encoded = try? JSONEncoder().encode(files) else { return nil }
            digest = encoded
        } else if let text, !text.isEmpty { digest = Data(text.utf8) } else { return nil }
        return SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
    }

    public func search(_ query: String, type: String? = nil, limit: Int = 100) -> [ClipboardRecord] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let maximum = max(1, min(limit, 100))
        // 插件没搜到目标时用 id 兜底，所以 id 命中优先于关键词过滤。
        if let hit = records.first(where: { $0.id == keyword }) { return [hit] }
        var matched: [ClipboardRecord] = []
        for record in records {
            if let type, record.type != type { continue }
            if !keyword.isEmpty, !record.searchable.contains(keyword) { continue }
            matched.append(record)
            if matched.count >= maximum { break }
        }
        return matched
    }

    public func remove(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        let removed = records.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        // 同一内容可能残留多条同 hash 的行，甚至分散在不同组里，必须全组按 hash 一起清掉。
        let hashes = Set(removed.map(\.hash))
        for group in try groupNames() {
            let stored = try read(group)
            let kept = stored.filter { !ids.contains($0.id) && !hashes.contains($0.hash) }
            guard kept.count != stored.count else { continue }
            try write(kept, to: group)
            // 图片与组同目录，行都删干净后再删图。
            for record in stored where hashes.contains(record.hash) {
                guard let name = record.imagePath else { continue }
                try? fileManager.removeItem(at: groupURL(group).appendingPathComponent(name))
            }
        }
        records.removeAll { ids.contains($0.id) || hashes.contains($0.hash) }
        if let currentGroup { currentGroupCount = (try? read(currentGroup).count) ?? 0 }
    }

    public func clearAll() throws {
        for group in try groupNames() { try? fileManager.removeItem(at: groupURL(group)) }
        records = []
        currentGroup = nil
        currentGroupCount = 0
    }

    // MARK: - 日志读写

    private func load() throws {
        let groups = try groupNames()
        var loaded: [ClipboardRecord] = []
        var firstGroupCount = 0
        for (index, group) in groups.prefix(maximumGroups).enumerated() {
            let stored = try read(group)
            if index == 0 { firstGroupCount = stored.count }
            // 组内按写入顺序追加，倒序即新到旧。
            for item in stored.reversed() {
                guard !loaded.contains(where: { $0.hash == item.hash }) else { continue }
                loaded.append(record(item, in: group))
                if loaded.count >= maximumRecords { break }
            }
            if loaded.count >= maximumRecords { break }
        }
        records = loaded
        currentGroup = groups.first
        currentGroupCount = firstGroupCount
    }

    private func groupNames() throws -> [String] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return !name.isEmpty && name.allSatisfy(\.isNumber)
                && groupURL(name).path.hasPrefix(directory.path)
                && fileManager.fileExists(atPath: groupURL(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 > $1 }
    }

    private func read(_ group: String) throws -> [Stored] {
        let url = groupURL(group).appendingPathComponent("data")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            try? decoder.decode(Stored.self, from: Data(line.utf8))
        }
    }

    private func appendLine(_ stored: Stored, to group: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(stored)
        data.append(10)
        let url = groupURL(group).appendingPathComponent("data")
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func write(_ stored: [Stored], to group: String) throws {
        guard !stored.isEmpty else {
            try? fileManager.removeItem(at: groupURL(group))
            if currentGroup == group {
                currentGroup = nil
                currentGroupCount = 0
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for item in stored {
            data.append(try encoder.encode(item))
            data.append(10)
        }
        try data.write(to: groupURL(group).appendingPathComponent("data"), options: .atomic)
    }

    private func writableGroup(at timestamp: Int64) throws -> String {
        if let currentGroup, currentGroupCount < groupSize { return currentGroup }
        var name = String(timestamp)
        while fileManager.fileExists(atPath: groupURL(name).path) { name = String((Int64(name) ?? timestamp) + 1) }
        try fileManager.createDirectory(at: groupURL(name), withIntermediateDirectories: true)
        currentGroup = name
        currentGroupCount = 0
        try removeOldGroups()
        return name
    }

    /// 组到期淘汰最老的整组，连同组内图片一起删除。
    private func removeOldGroups() throws {
        let groups = try groupNames()
        guard groups.count > maximumGroups else { return }
        let stale = Set(groups.dropFirst(maximumGroups))
        for group in stale { try? fileManager.removeItem(at: groupURL(group)) }
        records.removeAll { stale.contains($0.group) }
    }

    private func trimOverflow() throws {
        guard records.count > maximumRecords else { return }
        try remove(ids: Set(records[maximumRecords...].map(\.id)))
    }

    private func groupURL(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

    private func record(_ stored: Stored, in group: String) -> ClipboardRecord {
        ClipboardRecord(id: stored.id, type: stored.type, timestamp: stored.timestamp, hash: stored.hash,
                        group: group, text: stored.text, files: stored.files,
                        imagePath: stored.imagePath.map { groupURL(group).appendingPathComponent($0).path })
    }
}

extension ClipboardHistoryStore {
    /// 一次性把旧的「每记录一个 JSON + 独立图片目录」迁移成分组日志。
    /// 旧的 PluginData 与图片目录保留不删，失败时下次启动重试。
    public func migrateLegacyHistory(legacyDirectory: URL, documentStores: PluginDocumentStoreProvider,
                                     fileManager: FileManager = .default) {
        let marker = directory.appendingPathComponent(".migrated-v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        do {
            let documents = try documentStores.store(for: AppPaths.clipboardPluginID).allDocs()
            for document in documents.sorted(by: { legacyTimestamp($0) < legacyTimestamp($1) }) {
                try migrate(document, legacyDirectory: legacyDirectory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("1".utf8).write(to: marker, options: .atomic)
            Self.logger.debug("已迁移 \(documents.count) 条旧剪切板历史。")
        } catch {
            Self.logger.error("迁移旧剪切板历史失败：\(error.localizedDescription)")
        }
    }

    private func migrate(_ document: PluginValue, legacyDirectory: URL) throws {
        guard let type = document["type"]?.string else { return }
        let timestamp = Int64(legacyTimestamp(document))
        if let text = document["text"]?.string {
            if isMigrated(text: text, files: nil, image: nil) { return }
            try append(type: type, text: text, timestamp: timestamp)
        } else if case let .array(values)? = document["files"] {
            let files = values.compactMap(\.string)
            if isMigrated(text: nil, files: files, image: nil) { return }
            try append(type: type, files: files, timestamp: timestamp)
        } else if let relative = document["imagePath"]?.string,
                  let data = try? Data(contentsOf: legacyDirectory.appendingPathComponent(relative)) {
            if isMigrated(text: nil, files: nil, image: data) { return }
            try append(type: type, image: data, timestamp: timestamp)
        }
    }

    /// 迁移中途失败后下次会重跑，已迁移过的内容按 hash 跳过，避免重复行。
    private func isMigrated(text: String?, files: [String]?, image: Data?) -> Bool {
        guard let hash = contentHash(text: text, files: files, image: image) else { return false }
        return records.contains { $0.hash == hash }
    }

    private func legacyTimestamp(_ document: PluginValue) -> Double {
        guard case let .number(value) = document["timestamp"] else { return 0 }
        return value
    }
}
