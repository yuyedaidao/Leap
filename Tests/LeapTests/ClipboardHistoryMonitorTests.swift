import AppKit
import Foundation
import Testing
@testable import LeapCore

@MainActor
struct ClipboardHistoryMonitorTests {
    @MainActor private struct Fixture {
        let monitor: ClipboardHistoryMonitor
        let store: ClipboardHistoryStore
        let board: NSPasteboard
        let root: URL
        func close() {
            monitor.stop()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(maximumRecords: Int = 200) -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapClipboard-\(UUID().uuidString)")
        let store = ClipboardHistoryStore(directory: root.appendingPathComponent("clipboard-data"),
                                         maximumRecords: maximumRecords)
        let board = NSPasteboard(name: NSPasteboard.Name("LeapClipboardTests-\(UUID().uuidString)"))
        return Fixture(monitor: ClipboardHistoryMonitor(pasteboard: board, store: store), store: store,
                       board: board, root: root)
    }

    private func copyText(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @Test("文本按内容去重置顶，超出上限时删除最旧记录")
    func textDeduplicationAndLimit() throws {
        let fixture = fixture(maximumRecords: 2)
        defer { fixture.close() }
        copyText("第一条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        let firstID = try #require(fixture.store.records.first?.id)
        copyText("第二条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        copyText("第一条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        #expect(fixture.store.records.count == 2)
        let renewed = try #require(fixture.store.records.first)
        #expect(renewed.text == "第一条")
        #expect(renewed.id > firstID)
        #expect(!fixture.store.records.contains { $0.id == firstID })
        copyText("第三条", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        #expect(fixture.store.records.count == 2)
        #expect(fixture.store.records.compactMap(\.text) == ["第三条", "第一条"])
    }

    @Test("重复复制不追加新行")
    func adjacentDuplicate() throws {
        let fixture = fixture()
        defer { fixture.close() }
        copyText("同一段内容", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        copyText("同一段内容", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        #expect(fixture.store.records.count == 1)
    }

    @Test("宿主写入被跳过，下一次用户复制仍正常记录")
    func suppression() throws {
        let fixture = fixture()
        defer { fixture.close() }
        copyText("用户内容", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        copyText("宿主粘贴", to: fixture.board)
        fixture.monitor.suppressNextCapture()
        fixture.monitor.captureIfNeeded()
        #expect(fixture.store.records.count == 1)
        copyText("下一次复制", to: fixture.board)
        fixture.monitor.captureIfNeeded()
        #expect(fixture.store.records.count == 2)
    }

    @Test("文件只保存路径，图片保存 PNG 与绝对路径")
    func filesAndImage() throws {
        let fixture = fixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("示例.txt")
        try Data("test".utf8).write(to: file)
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([file as NSURL]))
        fixture.monitor.captureIfNeeded()
        let fileRecord = try #require(fixture.store.records.first)
        #expect(fileRecord.type == "files")
        #expect(fileRecord.files == [file.path])
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try #require(NSImage(data: png))
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([image]))
        fixture.monitor.captureIfNeeded()
        let imageRecord = try #require(fixture.store.records.first { $0.type == "image" })
        let imagePath = try #require(imageRecord.imagePath)
        #expect(imagePath.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: imagePath))
    }
}
