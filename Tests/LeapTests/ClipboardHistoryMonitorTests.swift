import AppKit
import Foundation
import Testing
@testable import LeapCore

@MainActor
struct ClipboardHistoryMonitorTests {
    @MainActor private struct Fixture {
        let monitor: ClipboardHistoryMonitor
        let store: PluginDocumentStore
        let board: NSPasteboard
        let paths: AppPaths
        let root: URL
        func close() {
            monitor.stop()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(maximumRecords: Int = 200) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapClipboard-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("Support"),
                             resourceDirectory: root.appendingPathComponent("Resources"))
        let provider = PluginDocumentStoreProvider(paths: paths)
        let board = NSPasteboard(name: NSPasteboard.Name("LeapClipboardTests-\(UUID().uuidString)"))
        let monitor = try ClipboardHistoryMonitor(paths: paths, pasteboard: board, documentStores: provider,
                                                 maximumRecords: maximumRecords)
        return Fixture(monitor: monitor, store: try provider.store(for: AppPaths.clipboardPluginID),
                       board: board, paths: paths, root: root)
    }

    private func copyText(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @Test("文本按内容去重置顶，超出上限时删除最旧记录及其目录")
    func textDeduplicationAndLimit() throws {
        let fixture = try fixture(maximumRecords: 2)
        defer { fixture.close() }
        copyText("第一条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        let firstID = try #require(try fixture.store.allDocs().first?["_id"]?.string)
        copyText("第二条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        copyText("第一条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        var documents = try fixture.store.allDocs()
        #expect(documents.count == 2)
        let renewed = try #require(documents.first { $0["text"] == .string("第一条") })
        #expect((renewed["_id"]?.string ?? "") > firstID)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.clipboardHistoryDirectory.appendingPathComponent(firstID).path
        ))
        copyText("第三条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        documents = try fixture.store.allDocs()
        #expect(documents.count == 2)
        #expect(documents.contains { $0["text"] == .string("第一条") })
        #expect(documents.contains { $0["text"] == .string("第三条") })
        #expect(!documents.contains { $0["text"] == .string("第二条") })
        for document in documents {
            let id = try #require(document["_id"]?.string)
            #expect(FileManager.default.fileExists(
                atPath: fixture.paths.clipboardHistoryDirectory.appendingPathComponent("\(id)/data").path
            ))
        }
    }

    @Test("宿主写入被跳过，下一次用户复制仍正常记录")
    func suppression() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        copyText("用户内容", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        copyText("宿主粘贴", to: fixture.board)
        fixture.monitor.suppressNextCapture()
        fixture.monitor.captureIfNeeded()
        #expect(try fixture.store.allDocs().count == 1)
        copyText("下一次复制", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        #expect(try fixture.store.allDocs().count == 2)
    }

    @Test("文件只保存路径，图片保存 PNG 与相对路径")
    func filesAndImage() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("示例.txt")
        try Data("test".utf8).write(to: file)
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([file as NSURL]))
        fixture.monitor.captureIfNeeded()
        let fileDocument = try #require(try fixture.store.allDocs().first)
        #expect(fileDocument["type"] == .string("files"))
        #expect(fileDocument["files"] == .array([.string(file.path)]))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try #require(NSImage(data: png))
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([image]))
        fixture.monitor.captureIfNeeded()
        let imageDocument = try #require(try fixture.store.allDocs().first { $0["type"] == .string("image") })
        let relativePath = try #require(imageDocument["imagePath"]?.string)
        #expect(!relativePath.hasPrefix("/"))
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.clipboardHistoryDirectory.appendingPathComponent(relativePath).path
        ))
    }
}
