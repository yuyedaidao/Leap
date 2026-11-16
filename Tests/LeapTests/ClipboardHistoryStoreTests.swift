import Foundation
import Testing
@testable import LeapCore

@MainActor
struct ClipboardHistoryStoreTests {
    private struct Fixture {
        let directory: URL
        let store: ClipboardHistoryStore
        let root: URL

        func close() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(maximumRecords: Int = 1000, groupSize: Int = 100) -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapClipboardStore-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("clipboard-data")
        return Fixture(directory: directory,
                       store: ClipboardHistoryStore(directory: directory, maximumRecords: maximumRecords,
                                                    groupSize: groupSize),
                       root: root)
    }

    private func groupNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.allSatisfy(\.isNumber) }
            .sorted()
    }

    @Test("组满后换新组，只保留最近的最大组数")
    func groupedAppend() throws {
        let fixture = fixture(maximumRecords: 6, groupSize: 3)
        defer { fixture.close() }
        for index in 0..<10 {
            try fixture.store.append(type: "text", text: "文本\(index)", timestamp: 1000 + Int64(index))
        }
        let groups = try groupNames(fixture.directory)
        #expect(groups.count == 3)
        #expect(fixture.store.records.count == 6)
        #expect(fixture.store.records.first?.text == "文本9")
        // 每行一条 JSON。
        for group in groups {
            let file = fixture.directory.appendingPathComponent(group).appendingPathComponent("data")
            let data = try Data(contentsOf: file)
            #expect(String(decoding: data, as: UTF8.self).split(separator: "\n").count <= 3)
        }
    }

    @Test("图片随记录写入组目录，淘汰时一起删除")
    func imagesFollowRecords() throws {
        let fixture = fixture(maximumRecords: 1, groupSize: 1)
        defer { fixture.close() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let record = try #require(try fixture.store.append(type: "image", image: png, timestamp: 2000))
        let imagePath = try #require(record.imagePath)
        #expect(FileManager.default.fileExists(atPath: imagePath))
        try fixture.store.append(type: "text", text: "后一次", timestamp: 2001)
        #expect(!FileManager.default.fileExists(atPath: imagePath))
        #expect(fixture.store.records.count == 1)
    }

    @Test("相邻与历史 hash 去重，内容保留在最新位置")
    func hashDeduplication() throws {
        let fixture = fixture()
        defer { fixture.close() }
        try fixture.store.append(type: "text", text: "A", timestamp: 3000)
        // 相邻重复直接忽略。
        #expect(try fixture.store.append(type: "text", text: "A", timestamp: 3001) == nil)
        try fixture.store.append(type: "text", text: "B", timestamp: 3002)
        // 非相邻的旧内容再复制一次，是新的动作，置顶并挤掉旧行。
        #expect(try fixture.store.append(type: "text", text: "A", timestamp: 3003) != nil)
        #expect(fixture.store.records.compactMap(\.text) == ["A", "B"])
        // 重新加载后仍按 hash 去重，旧行不会复活。
        let reloaded = ClipboardHistoryStore(directory: fixture.directory)
        #expect(reloaded.records.compactMap(\.text) == ["A", "B"])
    }

    @Test("搜索按关键词与类型过滤，最多返回 100 条")
    func search() throws {
        let fixture = fixture()
        defer { fixture.close() }
        try fixture.store.append(type: "text", text: "并发编程笔记", timestamp: 4000)
        try fixture.store.append(type: "text", text: "https://github.com/padding", timestamp: 4001)
        try fixture.store.append(type: "files", files: ["/tmp/并发报告.txt"], timestamp: 4002)
        try fixture.store.append(type: "image", image: Data([0xFF]), timestamp: 4003)
        #expect(fixture.store.search("").count == 4)
        #expect(fixture.store.search("并发").count == 2)
        #expect(fixture.store.search("并发", type: "files").count == 1)
        #expect(fixture.store.search("image").count == 1)
        #expect(fixture.store.search("不存在").isEmpty)
        for index in 0..<150 {
            try fixture.store.append(type: "text", text: "批量\(index)", timestamp: 5000 + Int64(index))
        }
        #expect(fixture.store.search("批量").count == 100)
        // 插件没命中缓存时用 id 兜底，必须能直接找到那一条。
        let newest = try #require(fixture.store.records.first)
        #expect(fixture.store.search(newest.id) == [newest])
    }

    @Test("删除与清空会重写组文件并重建内存列表")
    func removeAndClear() throws {
        let fixture = fixture(groupSize: 2)
        defer { fixture.close() }
        var identifiers: [String] = []
        for index in 0..<4 {
            let record = try #require(
                try fixture.store.append(type: "text", text: "记录\(index)", timestamp: 6000 + Int64(index))
            )
            identifiers.append(record.id)
        }
        try fixture.store.remove(ids: [identifiers[1], identifiers[2]])
        #expect(fixture.store.records.compactMap(\.text) == ["记录3", "记录0"])
        let reloaded = ClipboardHistoryStore(directory: fixture.directory)
        #expect(reloaded.records.compactMap(\.text) == ["记录3", "记录0"])
        try fixture.store.clearAll()
        #expect(fixture.store.records.isEmpty)
        #expect(try groupNames(fixture.directory).isEmpty)
    }

    @Test("删除按 hash 一并清掉残留行与图片")
    func removeDropsDuplicateLines() throws {
        let fixture = fixture()
        defer { fixture.close() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        _ = try fixture.store.append(type: "image", image: png, timestamp: 7000)
        _ = try fixture.store.append(type: "text", text: "中间", timestamp: 7001)
        let latest = try #require(try fixture.store.append(type: "image", image: png, timestamp: 7002))
        let imagePath = try #require(latest.imagePath)
        try fixture.store.remove(ids: [latest.id])
        #expect(fixture.store.records.compactMap(\.text) == ["中间"])
        #expect(!FileManager.default.fileExists(atPath: imagePath))
        // 组文件里的同 hash 旧行也要一起删，否则重载后会复活成图片丢失的记录。
        let reloaded = ClipboardHistoryStore(directory: fixture.directory)
        #expect(reloaded.records.compactMap(\.text) == ["中间"])
    }

    @Test("跨组的同内容旧行在删除最新一条时一并清掉")
    func removeAcrossGroups() throws {
        let fixture = fixture(maximumRecords: 10, groupSize: 2)
        defer { fixture.close() }
        _ = try fixture.store.append(type: "text", text: "A", timestamp: 8000)
        _ = try fixture.store.append(type: "text", text: "B", timestamp: 8001)
        _ = try fixture.store.append(type: "text", text: "C", timestamp: 8002)
        // A 第二次出现在新组里，旧组里的 A 行仍留在文件里。
        let latest = try #require(try fixture.store.append(type: "text", text: "A", timestamp: 8003))
        #expect(try groupNames(fixture.directory).count == 2)
        try fixture.store.remove(ids: [latest.id])
        #expect(fixture.store.records.compactMap(\.text) == ["C", "B"])
        let reloaded = ClipboardHistoryStore(directory: fixture.directory, groupSize: 2)
        #expect(reloaded.records.compactMap(\.text) == ["C", "B"])
    }

    @Test("旧文档库迁移成分组日志后可读，图片路径可用")
    func migration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapClipboardMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("Support"),
                             resourceDirectory: root.appendingPathComponent("Resources"))
        let provider = PluginDocumentStoreProvider(paths: paths)
        let legacyStore = try provider.store(for: AppPaths.clipboardPluginID)
        _ = try legacyStore.put(.object(["_id": .string("1000"), "type": .string("text"),
                                         "text": .string("旧文本"), "timestamp": .number(1000)]))
        // 旧图片记录：图片存放在 ClipboardHistory/<id>/<hash>.png。
        let legacyImage = paths.clipboardHistoryDirectory.appendingPathComponent("2000/abc.png")
        try FileManager.default.createDirectory(at: legacyImage.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: legacyImage)
        _ = try legacyStore.put(.object(["_id": .string("2000"), "type": .string("image"),
                                         "imagePath": .string("2000/abc.png"), "timestamp": .number(2000)]))
        let store = ClipboardHistoryStore(directory: paths.clipboardDataDirectory)
        store.migrateLegacyHistory(legacyDirectory: paths.clipboardHistoryDirectory, documentStores: provider)
        #expect(store.records.compactMap(\.text) == ["旧文本"])
        let image = try #require(store.records.first { $0.type == "image" })
        #expect(FileManager.default.fileExists(atPath: try #require(image.imagePath)))
        // 迁移只做一次。
        let again = ClipboardHistoryStore(directory: paths.clipboardDataDirectory)
        again.migrateLegacyHistory(legacyDirectory: paths.clipboardHistoryDirectory, documentStores: provider)
        #expect(again.records.count == 2)
        // 中途失败后重跑（marker 不在）时，已迁移的内容按 hash 跳过，不产生重复行。
        try FileManager.default.removeItem(at: paths.clipboardDataDirectory.appendingPathComponent(".migrated-v1"))
        again.migrateLegacyHistory(legacyDirectory: paths.clipboardHistoryDirectory, documentStores: provider)
        #expect(again.records.count == 2)
    }
}
