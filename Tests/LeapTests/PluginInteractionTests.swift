import Foundation
import Testing
@testable import LeapCore

struct PluginInteractionManifestTests {
    @Test("旧模式兼容，显式动作与网页共存，关键词和文本规则可安装")
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
        #expect(try PluginListItem.decode(#"{"items":[{"id":"one","title":"结果"}]}"#).first?.id == "one")
        #expect(try PluginListItem.decode(#"{"items":[]}"#).isEmpty)
        for value in [#"{"items":[{"id":"","title":"结果"}]}"#, #"{"items":[{"id":"a","title":""}]}"#,
                      #"{"items":[{"id":"a","title":"1"},{"id":"a","title":"2"}]}"#, #"{"items":"bad"}"#] {
            #expect(throws: PluginListItem.ListError.self) { try PluginListItem.decode(value) }
        }
        let excessive = (0...100).map { PluginListItem(id: String($0), title: "结果") }
        let encoded = try JSONEncoder().encode(["items": excessive])
        #expect(throws: PluginListItem.ListError.self) { try PluginListItem.decode(String(decoding: encoded, as: UTF8.self)) }
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
        let session = PluginListSession(debounce: .zero) { _, query, _, _ in
            if query == "bad" { throw PluginListItem.ListError.invalidResult }
            return #"{"items":[{"id":"ok","title":"恢复"}]}"#
        }
        session.updateInput("bad")
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.isError && !session.isLoading)
        session.updateInput("good")
        try await Task.sleep(for: .milliseconds(30))
        #expect(!session.isError && session.items.first?.id == "ok")
        session.close()
    }
}

private actor ListCallProbe {
    var queries: [String] = []
    var selections: [String] = []
    var running = 0
    var maximumRunning = 0

    func call(method: String, query: String, itemID: String?, cancellation: PluginInvocationCancellation) async throws -> String {
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        if method == "leap.query" { queries.append(query) } else { selections.append(itemID ?? "") }
        // 故意不响应取消，检验宿主自己的过期版本隔离，而不是只依赖插件配合。
        try await Task.sleep(for: .milliseconds(60))
        if method == "leap.select" { return "selected \(query)" }
        let data = try JSONEncoder().encode(["items": [PluginListItem(id: "result", title: query)]])
        return String(decoding: data, as: UTF8.self)
    }
}
