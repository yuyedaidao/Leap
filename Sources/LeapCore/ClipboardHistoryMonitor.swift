import AppKit
import CryptoKit
import Foundation
import YQLogger

/// 采集只负责写入剪切板插件的数据库；展示与粘贴仍由普通插件会话完成。
@MainActor
public final class ClipboardHistoryMonitor {
    private struct CapturedContent {
        let type: String
        let fields: [String: PluginValue]
        let digest: Data
        let image: Data?
    }

    private static let logger = YQLogger(label: "com.padding.leap/clipboard-history")
    private let directory: URL
    private let pasteboard: NSPasteboard
    private let store: PluginDocumentStore
    private let maximumRecords: Int
    private let fileManager: FileManager
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?

    public init(paths: AppPaths, pasteboard: NSPasteboard = .general,
                documentStores: PluginDocumentStoreProvider, maximumRecords: Int = 200,
                fileManager: FileManager = .default) throws {
        directory = paths.clipboardHistoryDirectory
        self.pasteboard = pasteboard
        store = try documentStores.store(for: AppPaths.clipboardPluginID)
        self.maximumRecords = max(1, maximumRecords)
        self.fileManager = fileManager
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureIfNeeded() }
        }
        timer.tolerance = 0.1
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func suppressNextCapture() {
        suppressedChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    /// 定时器和测试共用同一入口；一轮只读取当前快照，不补录错过中间状态。
    func captureIfNeeded() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return
        }
        do { try capture() } catch {
            Self.logger.error("记录剪切板历史失败：\(error.localizedDescription)")
        }
    }

    private func capture() throws {
        let content: CapturedContent?
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            content = CapturedContent(type: "files", fields: ["files": .array(paths.map(PluginValue.string))],
                                      digest: try JSONEncoder().encode(paths), image: nil)
        } else if let text = pasteboard.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = CapturedContent(type: "text", fields: ["text": .string(text)],
                                      digest: Data(text.utf8), image: nil)
        } else if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                  let image = images.first, let png = Self.pngData(image) {
            content = CapturedContent(type: "image", fields: [:], digest: png, image: png)
        } else { content = nil }
        guard let content else { return }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let id = try nextID(timestamp)
        let hash = SHA256.hash(data: content.digest).map { String(format: "%02x", $0) }.joined()
        var fields = content.fields
        fields["_id"] = .string(id)
        fields["type"] = .string(content.type)
        fields["timestamp"] = .number(Double(timestamp))
        fields["hash"] = .string(hash)
        if content.image != nil { fields["imagePath"] = .string("\(id)/\(hash).png") }
        try persist(.object(fields), image: content.image)
        try removeDuplicates(hash: hash, keeping: id)
        try trim()
    }

    private func nextID(_ timestamp: Int64) throws -> String {
        var candidate = timestamp
        while try store.get(String(candidate)) != nil ||
            fileManager.fileExists(atPath: directory.appendingPathComponent(String(candidate)).path) {
            candidate += 1
        }
        return String(candidate)
    }

    private func persist(_ document: PluginValue, image: Data?) throws {
        guard let id = document["_id"]?.string else { return }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: folder.appendingPathComponent("data"), options: .atomic)
            if let image, let path = document["imagePath"]?.string {
                try image.write(to: directory.appendingPathComponent(path), options: .atomic)
            }
            _ = try store.put(document)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private func removeDuplicates(hash: String, keeping id: String) throws {
        for document in try store.allDocs() where document["hash"]?.string == hash && document["_id"]?.string != id {
            try remove(document)
        }
    }

    private func trim() throws {
        let records = try store.allDocs().filter { $0["hash"]?.string != nil }.sorted { left, right in
            let leftTimestamp = timestamp(left)
            let rightTimestamp = timestamp(right)
            if leftTimestamp != rightTimestamp { return leftTimestamp > rightTimestamp }
            return (left["_id"]?.string ?? "") > (right["_id"]?.string ?? "")
        }
        for document in records.dropFirst(maximumRecords) { try remove(document) }
    }

    private func timestamp(_ document: PluginValue) -> Double {
        guard case let .number(value) = document["timestamp"] else { return 0 }
        return value
    }

    private func remove(_ document: PluginValue) throws {
        guard let id = document["_id"]?.string, let revision = document["_rev"]?.string else { return }
        _ = try store.remove(id, revision: revision)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        let representations = image.representations
        guard !representations.isEmpty, representations.allSatisfy({
            $0.pixelsWide > 0 && $0.pixelsHigh > 0 && $0.pixelsWide <= 64_000_000 / $0.pixelsHigh
        }), let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:]),
            !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        return data
    }
}
