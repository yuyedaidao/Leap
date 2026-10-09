import Foundation
import Testing
@testable import LeapCore

struct PluginInteractionProcessTests {
    @Test("查询输出超过管道缓冲区仍可返回，取消会终止等待")
    func outputAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapRPC-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let node = project.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node")
        let entry = root.appendingPathComponent("main.js")
        let script = """
        let input = '';
        process.stdin.on('data', chunk => input += chunk);
        process.stdin.on('end', () => {
          const request = JSON.parse(input);
          if (request.params.query === 'wait') { setTimeout(() => {}, 10000); return; }
          const result = request.params.query === 'oversize' ? 'x'.repeat(1100000)
            : request.params.query === 'large' ? 'x'.repeat(100000) : request.params.itemID;
          process.stdout.write(JSON.stringify({jsonrpc:'2.0', id:request.id, result}) + '\\n');
        });
        """
        try Data(script.utf8).write(to: entry)
        let runner = JSONRPCProcessRunner()
        #expect(try runner.invoke(executable: node, arguments: [entry.path], commandID: "test", query: "large",
                                  method: "leap.query").count == 100000)
        #expect(try runner.invoke(executable: node, arguments: [entry.path], commandID: "test", query: "select",
                                  method: "leap.select", itemID: "stable") == "stable")
        #expect(throws: JSONRPCProcessRunner.RunnerError.responseTooLarge) {
            try runner.invoke(executable: node, arguments: [entry.path], commandID: "test", query: "oversize")
        }
        #expect(throws: JSONRPCProcessRunner.RunnerError.responseTooLarge) {
            try runner.invoke(
                executable: node, arguments: [entry.path], commandID: "test",
                query: String(repeating: "x", count: 1100000)
            )
        }
        let token = PluginInvocationCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = ContinuousClock.now
        #expect(throws: JSONRPCProcessRunner.RunnerError.cancelled) {
            try runner.invoke(executable: node, arguments: [entry.path], commandID: "test", query: "wait", cancellation: token)
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }
    @Test("不读取输入的插件仍受超时限制")
    func blockedInputTimesOut() throws {
        let start = ContinuousClock.now
        #expect(throws: JSONRPCProcessRunner.RunnerError.timedOut) {
            try JSONRPCProcessRunner().invoke(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                commandID: "test", query: String(repeating: "x", count: 100000), timeout: 0.1
            )
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

}
