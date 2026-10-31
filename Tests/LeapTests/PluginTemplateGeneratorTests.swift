import Foundation
import Testing
@testable import LeapCore

struct PluginTemplateGeneratorTests {
    @Test("七种模板通过 Leap 原生校验、安装并运行", arguments: [
        (PluginManifest.Runtime.javascript, "action"), (.javascript, "web"), (.javascript, "list"),
        (.python, "action"), (.python, "web"), (.python, "list"), (.shell, "action")
    ])
    func generatedTemplates(runtime: PluginManifest.Runtime, interaction: String) async throws {
        let withUI = interaction == "web"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapTemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let paths = AppPaths(
            applicationSupportDirectory: destination.appendingPathComponent("Support"),
            resourceDirectory: root.appendingPathComponent("Resources/Leap")
        )
        let executor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        let generatorDirectory = root.appendingPathComponent("Resources/Leap/OfficialPlugins/TemplateGenerator")
        let validator = PluginManifestValidator()
        let generator = try validator.load(from: generatorDirectory)
        let generatedDirectory = destination.appendingPathComponent("插件 模板")
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: false)
        let values: [String: Any] = [
            "directory": generatedDirectory.path, "name": "测试插件", "version": "1.0.0",
            "runtime": runtime.rawValue, "interaction": interaction,
            "width": 800, "height": 600
        ]
        let query = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        _ = try await executor.invoke(
            manifest: generator, pluginDirectory: generatorDirectory, commandID: "template.generate", query: query
        )
        let manifest = try validator.load(from: generatedDirectory)
        #expect(manifest.id == "com.leap.plugin.u63d2u4ef6u20u6a21u677f")
        #expect(manifest.commands.first?.title == "测试插件")
        #expect(manifest.runtime == runtime)
        #expect(manifest.webEntry == (withUI ? "index.html" : nil))
        #expect(manifest.webWindow == (withUI ? .init(width: 800, height: 600) : nil))
        #expect(manifest.commands.first?.resolvedExecutionMode == .foreground)
        #expect(manifest.commands.first?.mode == (interaction == "action" ? .action : .interactive))
        #expect(manifest.minimumHostVersion == nil)
        let installer = PluginInstaller(paths: paths)
        let candidate = try installer.inspect(sourceDirectory: generatedDirectory)
        let installedDirectory = try installer.install(candidate, confirmed: true)
        #expect(InstalledPluginCatalog(paths: paths).loadPlugins().contains { $0.manifest == manifest })
        if runtime == .shell {
            try verifyShell(
                at: installedDirectory.appendingPathComponent(manifest.entry), commandID: manifest.commands[0].id
            )
        } else if interaction == "list" {
            let session = try executor.makeSession(manifest: manifest, pluginDirectory: installedDirectory,
                                                  commandID: "\(manifest.id).run", query: "Hello")
            defer { session.close() }
            let items = TestListUpdates()
            _ = try await session.call("input", query: "Hello", onList: items.update)
            #expect(items.values.map(\.title) == ["HELLO", "hello"])
            #expect(try await session.call("select", query: "Hello", itemID: "upper").string == "HELLO")
        } else {
            #expect(try await executor.invoke(
                manifest: manifest, pluginDirectory: installedDirectory,
                commandID: "\(manifest.id).run", query: ""
            ).string == "hello")
        }
        #expect(candidate.manifest == manifest)
    }

    @Test("多命令搜索、输入与图标通过原生校验并实际运行", arguments: [
        PluginManifest.Runtime.javascript, .python
    ])
    func multipleCommands(runtime: PluginManifest.Runtime) async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapMultiTemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let generated = destination.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupportDirectory: destination.appendingPathComponent("Support"),
                             resourceDirectory: project.appendingPathComponent("Resources/Leap"))
        let executor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        let source = paths.officialPluginsDirectory.appendingPathComponent("TemplateGenerator")
        let generator = try PluginManifestValidator().load(from: source)
        let commands: [[String: Any]] = [
            ["id": "direct.run", "title": "直接", "interaction": "action", "keywords": ["run", "运行"]],
            ["id": "list.run", "title": "列表", "interaction": "list",
             "input": ["enabled": true, "placeholder": "转换文本"],
             "matches": [["type": "text", "minLength": 2, "maxLength": 100]]],
            ["id": "web.run", "title": "网页", "interaction": "web",
             "input": ["enabled": true, "placeholder": "网页参数"],
             "matches": [["type": "regex", "pattern": "(?i)^hello$", "minLength": 1, "maxLength": 1000]]]
        ]
        let values: [String: Any] = [
            "directory": generated.path, "name": "多命令", "version": "1.0.0",
            "runtime": runtime.rawValue, "commands": commands, "includeIcon": true, "width": 800, "height": 600
        ]
        let query = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        _ = try await executor.invoke(manifest: generator, pluginDirectory: source,
                                commandID: "template.generate", query: query)
        let manifest = try PluginManifestValidator().load(from: generated)
        #expect(manifest.commands.count == 3)
        #expect(manifest.icon == "icon.png")
        #expect(manifest.commands[0].keywords == ["run", "运行"])
        #expect(manifest.commands[1].input?.placeholder == "转换文本")
        #expect(PluginCommandMatcher(command: manifest.commands[2]).matchesContent("HELLO"))
        let installer = PluginInstaller(paths: paths)
        let installed = try installer.install(installer.inspect(sourceDirectory: generated), confirmed: true)
        for commandID in ["direct.run", "web.run"] {
            #expect(try await executor.invoke(manifest: manifest, pluginDirectory: installed,
                                        commandID: commandID, query: "Hello").string == "hello")
        }
        let session = try executor.makeSession(manifest: manifest, pluginDirectory: installed,
                                              commandID: "list.run", query: "Hello")
        defer { session.close() }
        let items = TestListUpdates()
        _ = try await session.call("input", query: "Hello", onList: items.update)
        #expect(items.values.map(\.title) == ["HELLO", "hello"])
        #expect(try await session.call("select", query: "Hello", itemID: "lower").string == "hello")
    }

    private func verifyShell(at entry: URL, commandID: String) throws {
        // 独立启动 Shell 模板，验证真实脚本输出而非构建出来的文本。
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [entry.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LEAP_COMMAND_ID": commandID]
        ) { _, new in new }
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hello\n")
    }
}

/// 测试跨队列收集真实流式列表更新。
final class TestListUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PluginListItem] = []
    private var listTitle: String?
    var values: [PluginListItem] { lock.withLock { storage } }
    var title: String? { lock.withLock { listTitle } }
    func update(_ value: PluginListSnapshot) {
        lock.withLock { storage = value.items; listTitle = value.title }
    }
}
