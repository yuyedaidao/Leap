import Foundation
import Testing
@testable import LeapCore

/// 共享 daemon 的会话隔离与路由；用未修改的 bootstrap.cjs 与真实 Node 运行时验证。
struct PluginDaemonTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func daemon() -> PluginDaemon {
        PluginDaemon(
            executable: root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node"),
            script: root.appendingPathComponent("Resources/Leap/PluginSDK/daemon.cjs")
        )
    }

    private func plugin(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDaemon-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("main.js")
        try Data(script.utf8).write(to: entry)
        return (entry, directory)
    }

    private func session(_ daemon: PluginDaemon, entry: URL) -> PluginProcessSession {
        PluginProcessSession(
            executable: root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node"),
            arguments: [],
            hostCall: { _, _ in .bool(true) },
            transport: .daemon(daemon, session: UUID().uuidString, entry: entry)
        )
    }

    @Test("两个 JS 会话共享同一个 daemon 进程且各自正常收发")
    func sharedProcess() async throws {
        let daemon = daemon()
        defer { daemon.shutdown() }
        let (first, firstDirectory) = try plugin("leap.onInvoke(({query}) => 'A' + query);")
        let (second, secondDirectory) = try plugin("leap.onInvoke(({query}) => 'B' + query);")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let alpha = session(daemon, entry: first)
        let beta = session(daemon, entry: second)
        defer { alpha.close(); beta.close() }
        _ = try await alpha.request("enter", commandID: "test", query: "")
        _ = try await beta.request("enter", commandID: "test", query: "")
        // 同一 daemon 内所有 Worker 共享宿主进程，这正是省掉冷启的前提。
        #expect(alpha.processIdentifier == beta.processIdentifier)
        #expect(try await alpha.request("invoke", commandID: "test", query: "1").string == "A1")
        #expect(try await beta.request("invoke", commandID: "test", query: "2").string == "B2")
    }

    @Test("一个 Worker 退出后另一个会话继续工作")
    func crashedWorkerIsolation() async throws {
        let daemon = daemon()
        defer { daemon.shutdown() }
        let (first, firstDirectory) = try plugin("leap.onInvoke(() => { process.exit(0); });")
        let (second, secondDirectory) = try plugin("leap.onInvoke(() => 'alive');")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let alpha = session(daemon, entry: first)
        let beta = session(daemon, entry: second)
        defer { alpha.close(); beta.close() }
        _ = try await alpha.request("enter", commandID: "test", query: "")
        _ = try await beta.request("enter", commandID: "test", query: "")
        let started = Date()
        await #expect(throws: (any Error).self) {
            try await alpha.request("invoke", commandID: "test", query: "")
        }
        // Worker 退出要立刻上报，不能靠 3s 请求超时兜底。
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(try await beta.request("invoke", commandID: "test", query: "").string == "alive")
    }

    @Test("插件加载失败（bootstrap 转成 exit(1)）也立即上报")
    func loadFailureIsImmediate() async throws {
        let daemon = daemon()
        defer { daemon.shutdown() }
        let (entry, directory) = try plugin("throw new Error('加载失败');")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = session(daemon, entry: entry)
        defer { failed.close() }
        let started = Date()
        await #expect(throws: (any Error).self) {
            try await failed.request("enter", commandID: "test", query: "")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("并发宿主调用按会话隔离，host id 不串台")
    func hostCallIsolation() async throws {
        let daemon = daemon()
        defer { daemon.shutdown() }
        let script = "leap.onInvoke(async ({query}) => query + ':' + String(await leap.getAppName()));"
        let (first, firstDirectory) = try plugin(script)
        let (second, secondDirectory) = try plugin(script)
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let runtime = root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node")
        func make() -> PluginProcessSession {
            PluginProcessSession(
                executable: runtime, arguments: [],
                hostCall: { _, _ in
                    try await Task.sleep(for: .milliseconds(20))
                    return .string("Leap")
                },
                transport: .daemon(daemon, session: UUID().uuidString, entry: first)
            )
        }
        let alpha = make()
        let beta = PluginProcessSession(
            executable: runtime, arguments: [],
            hostCall: { _, _ in
                try await Task.sleep(for: .milliseconds(20))
                return .string("Leap")
            },
            transport: .daemon(daemon, session: UUID().uuidString, entry: second)
        )
        defer { alpha.close(); beta.close() }
        _ = try await alpha.request("enter", commandID: "test", query: "")
        _ = try await beta.request("enter", commandID: "test", query: "")
        async let left = alpha.request("invoke", commandID: "test", query: "L")
        async let right = beta.request("invoke", commandID: "test", query: "R")
        let values = try await [left, right]
        #expect(values.map(\.string) == ["L:Leap", "R:Leap"])
    }

    @Test("会话关闭后 daemon 仍存活，新会话立刻可用")
    func closeKeepsDaemonAlive() async throws {
        let daemon = daemon()
        defer { daemon.shutdown() }
        let (entry, directory) = try plugin("leap.onInvoke(() => 'ok');")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = session(daemon, entry: entry)
        _ = try await first.request("enter", commandID: "test", query: "")
        let pid = first.processIdentifier
        first.close()
        // 关一个 Worker 不能带走 daemon，这是「下次打开不用等 2.5s」的前提。
        try await Task.sleep(for: .milliseconds(300))
        let second = session(daemon, entry: entry)
        defer { second.close() }
        let started = Date()
        _ = try await second.request("enter", commandID: "test", query: "")
        #expect(second.processIdentifier == pid)
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(try await second.request("invoke", commandID: "test", query: "").string == "ok")
    }
}
