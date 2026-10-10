import Darwin
import Foundation
import Testing
@testable import LeapCore

struct PluginInteractionProcessTests {
    @Test("真实 SDK 标题与子标题经进程桥接同步到宿主")
    func titledListBridge() async throws {
        let (process, directory) = try session(script: """
        leap.onInputChange(({setList}) => setList([
          {id:'one',title:'结果',description:'济南市'}
        ], {title:'共1个结果'}));
        """)
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        let updates = TestListUpdates()
        let value = try await process.request("input", commandID: "test", query: "", onList: updates.update)
        let result = try PluginListSnapshot.decode(value)
        #expect(updates.title == "共1个结果" && result.title == updates.title)
        #expect(result.items.first?.description == "济南市")
    }

    @Test("加载开关限定当前列表事件，结束、失败及取消均清理")
    func explicitLoadingBridge() async throws {
        let (process, directory) = try session(script: """
        leap.onInputChange(async ({text, setList, signal}) => {
          await leap.showLoading();
          await leap.showLoading();
          if (text === 'wait') await new Promise(resolve => signal.addEventListener('abort', resolve, {once:true}));
          if (text === 'fail') throw new Error('测试失败');
          await leap.hideLoading();
          setList([{id:'one',title:'结果'}]);
        });
        leap.onInvoke(async () => { await leap.showLoading(); });
        """)
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        let updates = LoadingUpdates()
        _ = try await process.request("input", commandID: "test", query: "", onLoading: updates.update)
        #expect(updates.values == [true, true, false, false])
        await #expect(throws: (any Error).self) {
            try await process.request("input", commandID: "test", query: "fail", onLoading: updates.update)
        }
        #expect(updates.values.last == false)
        await #expect(throws: (any Error).self) {
            try await process.request("input", commandID: "test", query: "")
        }
        await #expect(throws: (any Error).self) {
            try await process.request("invoke", commandID: "test", query: "", onLoading: updates.update)
        }
        let token = PluginInvocationCancellation()
        let pending = Task {
            try await process.request("input", commandID: "test", query: "wait", cancellation: token,
                                      onLoading: updates.update)
        }
        try await Task.sleep(for: .milliseconds(100))
        token.cancel()
        await #expect(throws: PluginSessionError.cancelled) { try await pending.value }
        #expect(updates.values.last == false)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func session(script: String, hostWaitTimeout: TimeInterval = 60, hostCall: @escaping PluginProcessSession.HostCall = { _, _ in .bool(true) }) throws
        -> (PluginProcessSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeapSDK-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("main.js")
        try Data(script.utf8).write(to: entry)
        return (PluginProcessSession(
            executable: root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node"),
            arguments: [root.appendingPathComponent("Resources/Leap/PluginSDK/bootstrap.cjs").path, entry.path],
            hostCall: hostCall, hostWaitTimeout: hostWaitTimeout
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
            try await process.request("enter", commandID: "test", query: String(repeating: "x", count: 25 * 1024 * 1024))
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
        let (large, directory) = try session(script: "leap.onInvoke(() => 'x'.repeat(25 * 1024 * 1024));")
        defer { large.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await large.request("enter", commandID: "test", query: "")
        await #expect(throws: PluginSessionError.plugin("插件消息超过 24MB。")) {
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
    @Test("宿主等待不占用业务期限，完成后恢复剩余业务额度")
    func hostWaitBudget() async throws {
        let (process, directory) = try session(script: """
        leap.onInvoke(async ({ query }) => {
          await leap.getAppName();
          if (query === 'slow') await new Promise(resolve => setTimeout(resolve, 300));
          return 'ok';
        });
        """, hostCall: { _, _ in
            try await Task.sleep(for: .milliseconds(3100))
            return .string("Leap")
        })
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        #expect(try await process.request("invoke", commandID: "test", query: "", timeout: 0.2).string == "ok")
        await #expect(throws: PluginSessionError.timedOut) {
            try await process.request("invoke", commandID: "test", query: "slow", timeout: 0.2)
        }
    }

    @Test("宿主累计等待上限终止任务，过期输入取消宿主操作")
    func hostWaitLimitAndCancellation() async throws {
        let marker = PluginInvocationCancellation()
        let (process, directory) = try session(script: "leap.onInvoke(async () => String(await leap.getAppName()));",
                                             hostWaitTimeout: 0.1, hostCall: { _, _ in
            do { try await Task.sleep(for: .seconds(10)); return .string("不应返回") }
            catch { marker.cancel(); throw error }
        })
        defer { process.close(); try? FileManager.default.removeItem(at: directory) }
        _ = try await process.request("enter", commandID: "test", query: "")
        await #expect(throws: PluginSessionError.timedOut) {
            try await process.request("invoke", commandID: "test", query: "")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(marker.isCancelled)
        let cancelled = PluginInvocationCancellation()
        let stopped = PluginInvocationCancellation()
        let (second, secondDirectory) = try session(script: "leap.onInputChange(async () => { await leap.getAppName(); });",
                                                   hostCall: { _, _ in
            do { try await Task.sleep(for: .seconds(10)); return .string("不应返回") }
            catch { stopped.cancel(); throw error }
        })
        defer { second.close(); try? FileManager.default.removeItem(at: secondDirectory) }
        _ = try await second.request("enter", commandID: "test", query: "")
        let task = Task { try await second.request("input", commandID: "test", query: "", cancellation: cancelled) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: PluginSessionError.cancelled) { try await task.value }
        #expect(stopped.isCancelled)
    }

}

private final class LoadingUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func update(_ visible: Bool) { lock.withLock { storage.append(visible) } }
}
