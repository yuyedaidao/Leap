import AppKit
import Foundation
import Testing
@testable import LeapCore

struct PluginInteractionManifestTests {
    @Test("默认动作与网页共存，关键词和文本规则可安装")
    func validModes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in [
            PluginManifest.Command(id: "run", title: "运行"),
            .init(id: "run", title: "运行", mode: .action),
            .init(id: "run", title: "运行", mode: .interactive, presentation: .list, keywords: ["convert"],
                  matches: [.init(type: .text), .init(type: .regex, pattern: "^[A-Z]+$")]),
            .init(id: "run", title: "运行", mode: .interactive, presentation: .web, input: .init(enabled: false))
        ] {
            try PluginManifestValidator().validate(manifest(command), in: root)
        }
        let matcher = PluginCommandMatcher(command: .init(
            id: "run", title: "运行", matches: [.init(type: .regex, pattern: "^[A-Z]+$", minLength: 2, maxLength: 5)]
        ))
        #expect(matcher.matchesContent("ABC"))
        #expect(!matcher.matchesContent("abc"))
        #expect(!matcher.matchesContent("A"))
        #expect(!matcher.matchesContent("ABCDEF"))
    }

    @Test("拒绝交互配置冲突、无效匹配和不支持的最低版本")
    func invalidModes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in [
            PluginManifest.Command(id: "run", title: "运行", mode: .interactive),
            .init(id: "run", title: "运行", mode: .action, presentation: .list),
            .init(id: "run", title: "运行", mode: .interactive, presentation: .list, input: .init(enabled: false)),
            .init(id: "run", title: "运行", executionMode: .background, mode: .interactive, presentation: .list),
            .init(id: "run", title: "运行", keywords: [" "]),
            .init(id: "run", title: "运行", matches: [.init(type: .regex, pattern: "[")]),
            .init(id: "run", title: "运行", matches: [.init(type: .text, maxLength: 0)])
        ] {
            #expect(throws: (any Error).self) { try PluginManifestValidator().validate(manifest(command), in: root) }
        }
        #expect(throws: PluginManifestValidator.ValidationError.invalidInteraction) {
            try PluginManifestValidator().validate(manifest(.init(id: "run", title: "运行", mode: .interactive,
                                                                presentation: .list), runtime: .shell), in: root)
        }
        for version in ["9.0.0", "1.1", "1..0", "abc"] {
            #expect(throws: PluginManifestValidator.ValidationError.unsupportedHostVersion) {
                try PluginManifestValidator().validate(manifest(.init(id: "run", title: "运行"), version: version), in: root)
            }
        }
    }

    @Test("列表结构验证拒绝重复ID、空标题、过量与错误类型")
    func listValidation() throws {
        func decode(_ text: String) throws -> [PluginListItem] {
            try PluginListItem.decode(JSONDecoder().decode(PluginValue.self, from: Data(text.utf8)))
        }
        #expect(try decode(#"[{"id":"one","title":"结果"}]"#).first?.id == "one")
        #expect(try decode("[]").isEmpty)
        for value in [#"[{"id":"","title":"结果"}]"#, #"[{"id":"a","title":""}]"#,
                      #"[{"id":"a","title":"1"},{"id":"a","title":"2"}]"#,
                      #"[{"id":1,"title":"结果"}]"#, #"[{"id":"a","title":"结果","description":1}]"#,
                      #""bad""#] {
            #expect(throws: (any Error).self) { try decode(value) }
        }
        let excessive = (0...100).map { PluginListItem(id: String($0), title: "结果") }
        let value = try JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(excessive))
        #expect(throws: PluginListItem.ListError.self) { try PluginListItem.decode(value) }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapInteraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.js"))
        try Data().write(to: root.appendingPathComponent("index.html"))
        return root
    }

    private func manifest(
        _ command: PluginManifest.Command, runtime: PluginManifest.Runtime = .javascript, version: String = "1.1.0"
    ) -> PluginManifest {
        .init(id: "test", name: "Test", version: "1.0.0", runtime: runtime, entry: "main.js",
              commands: [command], webEntry: runtime == .shell ? nil : "index.html", minimumHostVersion: version)
    }
}

@MainActor
struct PluginListSessionTests {
    @Test("数字快捷键映射与修饰键边界")
    func shortcutMapping() {
        for (index, character) in "1234567890".enumerated() {
            #expect(LauncherListShortcut.index(for: String(character), modifiers: .command) == index)
            #expect(LauncherListShortcut.hint(at: index) == "⌘\(character)")
        }
        for key in ["", "a", "10", "１"] {
            #expect(LauncherListShortcut.index(for: key, modifiers: .command) == nil)
        }
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option],
                                             [.command, .control]] {
            #expect(LauncherListShortcut.index(for: "1", modifiers: flags) == nil)
        }
        #expect(LauncherListShortcut.index(for: "1", modifiers: [.command, .capsLock, .numericPad]) == 0)
        #expect(LauncherListShortcut.hint(at: -1) == nil)
        #expect(LauncherListShortcut.hint(at: 10) == nil)
    }

    @Test("旧列表与带标题快照校验，空白标题隐藏")
    func snapshotValidation() throws {
        func decode(_ text: String) throws -> PluginListSnapshot {
            try PluginListSnapshot.decode(JSONDecoder().decode(PluginValue.self, from: Data(text.utf8)))
        }
        #expect(try decode("[]").title == nil)
        #expect(try decode(#"{"items":[],"title":"共0个结果"}"#).title == "共0个结果")
        #expect(try decode(#"{"items":[],"title":"  \n "}"#).title == nil)
        for value in [#"{"items":[],"title":1}"#, #"{"items":[],"title":null}"#,
                      #"{"title":"missing"}"#, #"{"items":"invalid"}"#] {
            #expect(throws: (any Error).self) { try decode(value) }
        }
    }

    @Test("数字执行第十项、忙碌及自动重复不执行，越界和关闭失效")
    func numericSelection() async throws {
        let probe = ListCallProbe()
        let entries = (0..<11).map { PluginListItem(id: String($0), title: "结果") }
        let value = try JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(entries))
        let session = PluginListSession(debounce: .zero) { method, query, itemID, token, update in
            if method == "input" {
                try await Task.sleep(for: .milliseconds(30))
                return value
            }
            return try await probe.call(method: method, query: query, itemID: itemID,
                                        cancellation: token, update: update)
        }
        session.updateInput("query")
        #expect(!session.select(at: 0))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!session.select(at: -1))
        #expect(!session.select(at: 10))
        #expect(session.select(at: 9, isRepeat: true))
        #expect(!session.isSelecting)
        #expect(session.select(at: 9))
        #expect(session.selectedID == "9")
        #expect(session.select(at: 0))
        try await Task.sleep(for: .milliseconds(90))
        #expect(await probe.selections == ["9"])
        session.updateInput("next")
        #expect(session.select(at: 0))
        try await Task.sleep(for: .milliseconds(60))
        #expect(await probe.selections == ["9"])
        session.close()
        #expect(!session.select(at: 0))
    }

    @Test("标题与条目同步发布，新输入等待保留旧快照，迟到批次不会覆盖")
    func titledSnapshots() async throws {
        let session = PluginListSession(debounce: .zero) { _, query, _, _, update in
            try await Task.sleep(for: .milliseconds(30))
            let items = [PluginListItem(id: query, title: query, description: "子标题")]
            update(.init(items: items, title: "分批标题"))
            let item: PluginValue = .object(["id": .string(query), "title": .string(query),
                                            "description": .string("子标题")])
            return .object(["items": .array([item]), "title": .string(query)])
        }
        session.updateInput("first")
        try await Task.sleep(for: .milliseconds(60))
        #expect(session.title == "first" && session.items.first?.id == "first")
        session.updateInput("stale")
        try await Task.sleep(for: .milliseconds(10))
        session.updateInput("latest")
        #expect(session.title == "first" && session.isLoading)
        try await Task.sleep(for: .milliseconds(90))
        #expect(session.title == "latest" && session.items.first?.id == "latest")
        session.close()
        #expect(session.title == nil)
    }

    @Test("防抖只查询最新输入，并发有界且旧响应不覆盖")
    func debounceAndStaleResponses() async throws {
        let probe = ListCallProbe()
        let session = PluginListSession(debounce: .milliseconds(10), call: probe.call)
        session.updateInput("first")
        try await Task.sleep(for: .milliseconds(25))
        session.updateInput("middle")
        session.updateInput("latest")
        try await Task.sleep(for: .milliseconds(180))
        #expect(session.items.first?.title == "latest")
        #expect(await probe.queries == ["first", "latest"])
        #expect(await probe.maximumRunning == 1)
        session.close()
    }

    @Test("选择传递稳定条目ID，重复选择不执行，关闭后结果不回写")
    func selectionAndClose() async throws {
        let probe = ListCallProbe()
        let session = PluginListSession(debounce: .zero, call: probe.call)
        session.updateInput("text")
        try await Task.sleep(for: .milliseconds(90))
        session.select()
        session.select()
        try await Task.sleep(for: .milliseconds(90))
        #expect(await probe.selections == ["result"])
        #expect(session.message == "selected text")
        session.updateInput("closed")
        try await Task.sleep(for: .milliseconds(10))
        session.close()
        try await Task.sleep(for: .milliseconds(90))
        #expect(session.items.isEmpty)
    }

    @Test("选择执行期间的新输入合并为后续查询，旧动作反馈不覆盖新参数")
    func inputWhileSelecting() async throws {
        let probe = ListCallProbe()
        let session = PluginListSession(debounce: .zero, call: probe.call)
        session.updateInput("old")
        try await Task.sleep(for: .milliseconds(90))
        session.select()
        session.updateInput("next")
        session.select()
        try await Task.sleep(for: .milliseconds(180))
        #expect(await probe.queries == ["old", "next"])
        #expect(await probe.selections == ["result"])
        #expect(await probe.maximumRunning == 1)
        #expect(session.items.first?.title == "next")
        #expect(session.message == nil)
        session.close()
    }

    @Test("调用失败后输入可恢复正常结果")
    func errorRecovery() async throws {
        let session = PluginListSession(debounce: .zero) { _, query, _, _, update in
            if query == "bad" { throw PluginListItem.ListError.invalidResult }
            update(.init(items: [PluginListItem(id: "ok", title: "恢复")]))
            return .array([.object(["id": .string("ok"), "title": .string("恢复")])])
        }
        session.updateInput("bad")
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.isError && !session.isLoading)
        session.updateInput("good")
        try await Task.sleep(for: .milliseconds(30))
        #expect(!session.isError && session.items.first?.id == "ok")
        session.close()
    }

    @Test("最终列表与加载完成同时发布，迟到的分批更新不能覆盖")
    func finalSnapshot() async throws {
        let session = PluginListSession(debounce: .zero) { _, _, _, _, update in
            for index in 0..<100 {
                update(.init(items: [PluginListItem(id: "partial", title: String(index))], title: "过期标题"))
            }
            return .array([.object(["id": .string("final"), "title": .string("完成")])])
        }
        session.updateInput("query")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!session.isLoading && session.items.first?.id == "final")
        #expect(session.selectedID == "final")
        #expect(session.title == nil)
        session.close()
    }
}

private actor ListCallProbe {
    var queries: [String] = []
    var selections: [String] = []
    var running = 0
    var maximumRunning = 0

    func call(method: String, query: String, itemID: String?, cancellation: PluginInvocationCancellation, update: @escaping PluginProcessSession.ListUpdate) async throws -> PluginValue {
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        if method == "input" { queries.append(query) } else { selections.append(itemID ?? "") }
        // 故意不响应取消，检验宿主自己的过期版本隔离，而不是只依赖插件配合。
        try await Task.sleep(for: .milliseconds(60))
        if method == "select" { return .string("selected \(query)") }
        update(.init(items: [PluginListItem(id: "result", title: query)]))
        return .array([.object(["id": .string("result"), "title": .string(query)])])
    }
}
