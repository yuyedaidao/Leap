import Foundation
import Testing
@testable import LeapCore

struct PluginDocumentStoreTests {
    private func fixture() throws -> (PluginDocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapDocumentStore-\(UUID().uuidString)")
        return (PluginDocumentStore(directory: root.appendingPathComponent("db")), root)
    }

    @Test("文档版本校验、更新删除与重新打开后的持久化")
    func revisionAndPersistence() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.put(.object(["_id": .string("note-1"), "text": .string("旧内容")]))
        let firstRevision = try #require(created["rev"]?.string)
        #expect(created["ok"] == .bool(true))
        #expect(try store.get("note-1")?["text"] == .string("旧内容"))
        #expect(throws: PluginDocumentStore.StoreError.conflict) {
            _ = try store.put(.object(["_id": .string("note-1"), "_rev": .string("stale"), "text": .string("错误")]))
        }
        #expect(throws: PluginDocumentStore.StoreError.conflict) {
            _ = try store.put(.object(["_id": .string("note-1"), "text": .string("缺少版本")]))
        }
        let updated = try store.put(.object(["_id": .string("note-1"), "_rev": .string(firstRevision),
                                             "text": .string("新内容")]))
        let secondRevision = try #require(updated["rev"]?.string)
        #expect(secondRevision != firstRevision)
        let reopened = PluginDocumentStore(directory: root.appendingPathComponent("db"))
        #expect(try reopened.get("note-1")?["text"] == .string("新内容"))
        #expect(try reopened.allDocs().count == 1)
        #expect(throws: PluginDocumentStore.StoreError.conflict) {
            _ = try reopened.remove("note-1", revision: firstRevision)
        }
        #expect(try reopened.remove("note-1", revision: secondRevision)["ok"] == .bool(true))
        #expect(try reopened.get("note-1") == nil)
        #expect(throws: PluginDocumentStore.StoreError.missingDocument) {
            _ = try reopened.remove("note-1", revision: secondRevision)
        }
    }

    @Test("拒绝非法标识、非对象文档和超过 1MB 的文档")
    func validation() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PluginDocumentStore.StoreError.invalidDocument) { _ = try store.put(.array([])) }
        #expect(throws: PluginDocumentStore.StoreError.invalidIdentifier) {
            _ = try store.put(.object(["_id": .string("../escape")]))
        }
        #expect(throws: PluginDocumentStore.StoreError.invalidIdentifier) { _ = try store.get("a/b") }
        #expect(throws: PluginDocumentStore.StoreError.documentTooLarge) {
            _ = try store.put(.object(["_id": .string("large"),
                                       "text": .string(String(repeating: "中", count: 1024 * 1024))]))
        }
        #expect(try store.allDocs().isEmpty)
    }
}
