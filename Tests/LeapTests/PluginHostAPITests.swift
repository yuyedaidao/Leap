import AppKit
import Foundation
import Testing
@testable import LeapCore

@MainActor
struct PluginHostAPITests {
    private struct Fixture {
        let api: PluginHostAPI
        let board: NSPasteboard
        let defaults: UserDefaults
        let name: String
        let root: URL
        func close() {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func service() -> Fixture {
        let name = "LeapHostTests-\(UUID())"
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let paths = AppPaths(applicationSupportDirectory: root, resourceDirectory: URL(fileURLWithPath: "/tmp"))
        return Fixture(api: PluginHostAPI(paths: paths, pasteboard: board, defaults: defaults),
                       board: board, defaults: defaults, name: name, root: root)
    }

    private func context() -> PluginHostAPI.Context {
        .init(pluginID: "test", commandIDs: ["run"], targetPID: nil, isActive: { true }, setWindowHidden: { _ in })
    }

    @Test("网页与动作宿主拒绝列表加载接口")
    func loadingRequiresNativeList() async throws {
        let fixture = service()
        defer { fixture.close() }
        for method in ["showLoading", "hideLoading"] {
            do {
                _ = try await fixture.api.handle(method, params: .object([:]), context: context())
                Issue.record("不支持的展示模式接受了加载接口")
            } catch {
                #expect(error.localizedDescription.contains("仅支持原生列表"))
            }
        }
    }

    @Test("隔离剪贴板复制文本、文件与图片，校验失败不覆盖原内容")
    func clipboard() async throws {
        let fixture = service()
        let api = fixture.api
        let board = fixture.board
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("test".utf8).write(to: file)
        _ = try await api.handle("copyText", params: .object(["text": .string("中文😀")]), context: context())
        #expect(board.string(forType: .string) == "中文😀")
        await #expect(throws: (any Error).self) {
            try await api.handle("copyFile", params: .object(["filePath": .array([.string(file.path),
                .string("/missing")])]), context: context())
        }
        #expect(board.string(forType: .string) == "中文😀")
        _ = try await api.handle("copyFile", params: .object(["filePath": .array([.string(file.path),
            .string(directory.path)])]), context: context())
        let copied = try await api.handle("getCopyedFiles", params: .object([:]), context: context())
        guard case let .array(files) = copied else { Issue.record("未返回文件列表"); return }
        #expect(files.count == 2)
        #expect(files[0]["isFile"] == .bool(true))
        #expect(files[1]["isDiractory"] == .bool(true))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                       bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = "data:image/png;base64," + png.base64EncodedString()
        _ = try await api.handle("copyImage", params: .object(["image": .string(image)]), context: context())
        #expect(board.canReadObject(forClasses: [NSImage.self], options: nil))
        await #expect(throws: (any Error).self) {
            try await api.handle("copyImage",
                params: .object(["image": .string("data:image/png;base64,AAAA")]), context: context())
        }
        #expect(board.canReadObject(forClasses: [NSImage.self], options: nil))
    }

    @Test("插件数据库按插件隔离并支持读写")
    func documentDatabase() async throws {
        let fixture = service()
        defer { fixture.close() }
        let created = try await fixture.api.handle("dbPut", params: .object([
            "doc": .object(["_id": .string("entry"), "value": .string("内容")])
        ]), context: context())
        let revision = try #require(created["rev"]?.string)
        let fetched = try await fixture.api.handle("dbGet", params: .object(["id": .string("entry")]),
                                                   context: context())
        #expect(fetched["value"] == .string("内容"))
        let other = PluginHostAPI.Context(pluginID: "other", commandIDs: [], targetPID: nil,
                                          isActive: { true }, setWindowHidden: { _ in })
        #expect(try await fixture.api.handle("dbAllDocs", params: .object([:]), context: other) == .array([]))
        _ = try await fixture.api.handle("dbRemove", params: .object([
            "id": .string("entry"), "rev": .string(revision)
        ]), context: context())
        #expect(try await fixture.api.handle("dbGet", params: .object(["id": .string("entry")]),
                                             context: context()) == .null)
    }

    @Test("路径映射、图标、UUID 持久性和通知命令校验")
    func system() async throws {
        let fixture = service()
        let api = fixture.api
        defer { fixture.close() }
        for path in ["home", "appData", "userData", "temp", "exe", "desktop", "documents", "downloads",
            "music", "pictures", "videos", "logs"] {
            #expect(try api.path(path).hasPrefix("/"))
        }
        #expect(throws: (any Error).self) { try api.path("invalid") }
        #expect(throws: (any Error).self) { try PluginHostAPI.fileURL("relative") }
        let first = try await api.handle("getNativeId", params: .object([:]), context: context())
        #expect(first == (try await api.handle("getNativeId", params: .object([:]), context: context())))
        #expect(UUID(uuidString: try #require(first.string)) != nil)
        #expect(try await api.handle("isMacOS", params: .object([:]), context: context()) == .bool(true))
        #expect(try await api.handle("getFileIcon", params: .object(["filePath": .string(".txt")]),
            context: context()).string?.hasPrefix("data:image/png;base64,") == true)
        await #expect(throws: (any Error).self) {
            try await api.handle("showNotification", params: .object(["body": .string("test"),
                "clickFeatureCode": .string("unknown")]), context: context())
        }
        await #expect(throws: PluginSessionError.closed) {
            try await api.handle("shellBeep", params: .object([:]), context: .init(
                pluginID: "test", commandIDs: [], targetPID: nil, isActive: { false }, setWindowHidden: { _ in }
            ))
        }
    }

    @Test("外部输入成功、权限拒绝、焦点失败与取消，不向真实窗口发送按键")
    func externalInput() async throws {
        let fixture = service()
        let api = fixture.api
        let board = fixture.board
        defer { fixture.close() }
        var visibility: [Bool] = []
        var text: [UInt16] = []
        var pasted = false
        let inputContext = PluginHostAPI.Context(pluginID: "test", commandIDs: ["run"], targetPID: 42,
                                                isActive: { true }, setWindowHidden: { visibility.append($0) })
        api.inputEnvironment.isAlive = { _ in true }
        var events: [String] = []
        api.inputEnvironment.activate = { _ in events.append("activate"); return true }
        api.inputEnvironment.frontmostPID = { 42 }
        api.inputEnvironment.requirePermission = {}
        api.inputEnvironment.type = { text.append(contentsOf: $0) }
        api.inputEnvironment.paste = { pasted = true; events.append("paste") }
        _ = try await api.handle("hideMainWindowTypeString", params: .object(["text": .string("中文😀👨‍👩‍👧‍👦")]),
            context: inputContext)
        #expect(String(decoding: text, as: UTF16.self) == "中文😀👨‍👩‍👧‍👦")
        #expect(visibility == [true])
        #expect(board.string(forType: .string) == nil)
        _ = try await api.handle("hideMainWindowPasteText", params: .object(["text": .string("paste")]),
            context: inputContext)
        #expect(pasted)
        #expect(board.string(forType: .string) == "paste")
        #expect(Array(events.suffix(2)) == ["activate", "paste"])
        api.inputEnvironment.requirePermission = { throw PluginSessionError.plugin("权限拒绝") }
        visibility = []
        await #expect(throws: (any Error).self) {
            try await api.handle("hideMainWindowPasteText", params: .object(["text": .string("不应复制")]),
                context: inputContext)
        }
        #expect(visibility.isEmpty)
        #expect(board.string(forType: .string) == "paste")
        api.inputEnvironment.requirePermission = {}
        api.inputEnvironment.activate = { _ in false }
        await #expect(throws: (any Error).self) {
            try await api.handle("hideMainWindowTypeString", params: .object(["text": .string("不应输入")]),
                context: inputContext)
        }
        #expect(visibility == [true, false])
        api.inputEnvironment.activate = { _ in true }
        let task = Task { try await api.handle("hideMainWindowTypeString",
            params: .object(["text": .string("取消")]), context: inputContext) }
        task.cancel()
        await #expect(throws: PluginSessionError.cancelled) { try await task.value }
        #expect(String(decoding: text, as: UTF16.self) == "中文😀👨‍👩‍👧‍👦")
    }

    @Test("键名与修饰键映射，Unicode 分段不破坏代理对")
    func keyboard() throws {
        let (key, flags) = try PluginKeyboard.decode("V", modifiers: ["cmd", "command", "shift"])
        #expect(key == 9)
        #expect(flags == [.maskCommand, .maskShift])
        for key in ["enter", "Escape", "F20", "delete", "pageup", "up"] { _ = try PluginKeyboard.decode(key,
            modifiers: []) }
        #expect(throws: (any Error).self) { try PluginKeyboard.decode("unknown", modifiers: []) }
        #expect(throws: (any Error).self) { try PluginKeyboard.decode("a", modifiers: ["unknown"]) }
        let text = String(repeating: "中文😀👨‍👩‍👧‍👦", count: 4)
        let chunks = PluginKeyboard.unicodeChunks(text)
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == text)
    }

    @Test("系统 API 示例符合真实安装清单规则")
    func exampleManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try PluginManifestValidator().load(from: root.appendingPathComponent("Examples/Plugins/HostAPI"))
        #expect(manifest.id == "com.example.leap.host-api")
        #expect(manifest.commands.first?.mode == nil)
        #expect(manifest.webEntry == "index.html")
    }

    @Test("不可取消的系统等待不会阻塞调用者结束")
    func cancelledSystemWait() async throws {
        let underlying = Task<Void, any Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
        }
        let start = ContinuousClock.now
        let waiting = Task { try await PluginCancellableOperation.value(of: underlying) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(start.duration(to: .now) < .milliseconds(200))
        try await underlying.value
    }

    @Test("仅临时文件移入废纸篓，并恢复清理测试数据")
    func trashTemporaryFile() async throws {
        let fixture = service()
        defer { fixture.close() }
        let name = "LeapTrashTest-\(UUID()).txt"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/" + name)
        try Data("disposable test".utf8).write(to: file)
        defer {
            // 测试只恢复本次生成的 UUID 文件，不读取或清空用户废纸篓。
            if FileManager.default.fileExists(atPath: trashed.path) {
                try? FileManager.default.moveItem(at: trashed, to: file)
            }
            try? FileManager.default.removeItem(at: file)
        }
        _ = try await fixture.api.handle("shellTrashItem", params: .object(["fullPath": .string(file.path)]),
                                        context: context())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
