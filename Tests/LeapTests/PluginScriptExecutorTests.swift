import Foundation
import Testing
@testable import LeapCore

struct PluginScriptExecutorTests {
    @Test("Python 插件不写入字节码缓存，保持应用资源封印有效")
    func pythonPluginsDoNotWriteBytecode() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapBytecodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("value = 1".utf8).write(to: directory.appendingPathComponent("helper.py"))
        try Data("""
        import sys
        import helper
        leap.onInvoke(lambda _: str(sys.dont_write_bytecode))
        """.utf8).write(to: directory.appendingPathComponent("main.py"))
        let paths = AppPaths(
            applicationSupportDirectory: directory.appendingPathComponent("Support"),
            resourceDirectory: root.appendingPathComponent("Resources/Leap")
        )
        let executor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        let manifest = PluginManifest(
            id: "test.bytecode", name: "Bytecode", version: "1.0.0", runtime: .python,
            entry: "main.py", commands: [.init(id: "check", title: "Check")]
        )
        let result = try await executor.invoke(
            manifest: manifest, pluginDirectory: directory, commandID: "check", query: ""
        )
        #expect(result.string == "True")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("__pycache__").path))
    }
}
