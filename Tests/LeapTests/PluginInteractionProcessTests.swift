import Darwin
import Foundation
import Testing
@testable import LeapCore

struct PluginInteractionProcessTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func session(script: String, hostCall: @escaping PluginProcessSession.HostCall = { _, _ in .bool(true) }) throws
        -> (PluginProcessSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeapSDK-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("main.js")
        try Data(script.utf8).write(to: entry)
        return (PluginProcessSession(
            executable: root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node"),
            arguments: [root.appendingPathComponent("Resources/Leap/PluginSDK/bootstrap.cjs").path, entry.path],
            hostCall: hostCall
        ), directory)
    }

    @Test("同一会话复用进程、输出排空且响应可以超过管道缓冲区")
    func reuseAndLargeOutput() async throws {
        let (process, directory) = try session(script: """
        let count = 0;
        leap.onInvoke(({query}) => query === 'large' ? 'x'.repeat(100000) : String(++count));
        """)
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        let pid = process.processIdentifier
        #expect(try await process.request("invoke", commandID: "test", query: "large").string?.count == 100000)
        for value in 1...20 {
            #expect(try await process.request("invoke", commandID: "test", query: "").string == String(value))
            #expect(process.processIdentifier == pid)
        }
    }

    @Test("取消信号结束异步查询，过期更新不发布，新输入正常执行")
    func cancellationAndStreaming() async throws {
        let (process, directory) = try session(script: """
        leap.onInputChange(async ({text, setList, signal}) => {
          if (text === 'wait') await new Promise(resolve => signal.addEventListener('abort', resolve, {once:true}));
          setList([{id:'result', title:text}]);
        });
        """)
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        let values = TestListUpdates()
        let cancellation = PluginInvocationCancellation()
        let task = Task {
            try await process.request("input", commandID: "test", query: "wait",
                                      cancellation: cancellation, onList: values.update)
        }
        try await Task.sleep(for: .milliseconds(40))
        cancellation.cancel()
        await #expect(throws: PluginSessionError.cancelled) { try await task.value }
        #expect(values.values.isEmpty)
        _ = try await process.request("input", commandID: "test", query: "latest", onList: values.update)
        #expect(values.values.first?.title == "latest")
    }

    @Test("双向调用独立处理，不等待业务回调结束，业务异常后仍可继续")
    func hostCallAndRecovery() async throws {
        let (process, directory) = try session(script: """
        leap.onInvoke(async ({query}) => {
          if (query === 'bad') throw new Error('业务失败');
          return String(await leap.copyText(query));
        });
        """, hostCall: { method, params in
            #expect(method == "copyText")
            #expect(params["text"]?.string == "Hello")
            return .bool(true)
        })
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        await #expect(throws: PluginSessionError.plugin("业务失败")) {
            try await process.request("invoke", commandID: "test", query: "bad")
        }
        #expect(try await process.request("invoke", commandID: "test", query: "Hello").string == "true")
    }

    @Test("不就绪、阻塞输入和超限请求均有界失败")
    func deadlinesAndLimits() async throws {
        let sleeping = PluginProcessSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        defer { sleeping.close() }
        await #expect(throws: PluginSessionError.timedOut) {
            try await sleeping.request("enter", commandID: "test", query: String(repeating: "x", count: 100000), timeout: 0.1)
        }
        let (process, directory) = try session(script: "leap.onInvoke(() => 'ok');")
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: PluginSessionError.messageTooLarge) {
            try await process.request("enter", commandID: "test", query: String(repeating: "x", count: 1100000))
        }
    }

    @Test("忽略 SIGTERM 的进程仍在退出宽限后强制释放")
    func forcedClose() async throws {
        let (process, directory) = try session(script: """
        process.on('SIGTERM', () => {});
        leap.onExit(() => new Promise(() => {}));
        """)
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        let pid = process.processIdentifier
        process.close()
        try await Task.sleep(for: .milliseconds(700))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("协议损坏拒绝继续执行，超限输出返回中文错误")
    func invalidFramesAndOversizedOutput() async throws {
        let (invalid, firstDirectory) = try session(script: "process.stdout.write('invalid\\n');")
        defer { invalid.close(); try? FileManager.default.removeItem(at: firstDirectory) }
        await #expect(throws: PluginSessionError.invalidMessage) {
            try await invalid.request("enter", commandID: "test", query: "")
        }
        let (large, directory) = try session(script: "leap.onInvoke(() => 'x'.repeat(1100000));")
        defer { large.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await large.request("enter", commandID: "test", query: "")
        await #expect(throws: PluginSessionError.plugin("插件消息超过 1MB。")) {
            try await large.request("invoke", commandID: "test", query: "")
        }
    }

    @Test("同步死循环超时终止进程，关闭中的调用完成而不泄漏")
    func hungProcessAndClose() async throws {
        let (process, directory) = try session(script: "leap.onInvoke(() => { while (true) {} });")
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        await #expect(throws: PluginSessionError.timedOut) {
            try await process.request("invoke", commandID: "test", query: "", timeout: 0.1)
        }
        await #expect(throws: PluginSessionError.closed) {
            try await process.request("invoke", commandID: "test", query: "")
        }
    }
}
