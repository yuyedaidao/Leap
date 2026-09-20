import Foundation
import Testing
@testable import LeapCore

struct LauncherShellTests {
    @Test("受管路径保持在 Leap 数据目录内")
    func managedPathsStayInsideLeapDirectories() throws {
        let supportDirectory = URL(fileURLWithPath: "/tmp/LeapTests/Application Support/Leap")
        let resourceDirectory = URL(fileURLWithPath: "/tmp/LeapTests/Resources")
        let paths = AppPaths(
            applicationSupportDirectory: supportDirectory,
            resourceDirectory: resourceDirectory
        )

        let pluginDirectory = try paths.managedPluginDirectory(for: "com.example.echo")

        #expect(pluginDirectory.path.hasPrefix(paths.pluginsDirectory.path + "/"))
        #expect(paths.runtimesDirectory.path.hasPrefix(paths.resourceDirectory.path + "/"))
    }

    @Test("插件标识符不能逃逸受管目录")
    func pluginIdentifierCannotEscapeManagedDirectory() {
        let paths = AppPaths(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/LeapTests/Application Support/Leap"),
            resourceDirectory: URL(fileURLWithPath: "/tmp/LeapTests/Resources")
        )

        #expect(throws: AppPaths.PathError.invalidPluginIdentifier) {
            _ = try paths.managedPluginDirectory(for: "../outside")
        }
    }

    @Test("插件清单校验覆盖必填字段、入口和重复 ID")
    func pluginManifestValidation() throws {
        let directory = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let validManifest = PluginManifest(
            id: "com.example.echo",
            name: "Echo",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "echo", title: "Echo")],
            webEntry: nil
        )
        try Data("print('echo')".utf8).write(to: directory.appendingPathComponent("main.py"))
        try JSONEncoder().encode(validManifest).write(to: directory.appendingPathComponent("manifest.json"))

        let validator = PluginManifestValidator()
        #expect(try validator.load(from: directory) == validManifest)
        #expect(throws: PluginManifestValidator.ValidationError.duplicatePluginID) {
            _ = try validator.load(from: directory, installedPluginIDs: [validManifest.id])
        }

        try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(throws: PluginManifestValidator.ValidationError.malformedManifest) {
            _ = try validator.load(from: directory)
        }
    }

    @Test("插件清单拒绝缺失入口和命令")
    func pluginManifestRejectsMissingEntryAndCommands() throws {
        let directory = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let validator = PluginManifestValidator()
        let manifest = PluginManifest(
            id: "com.example.invalid",
            name: "Invalid",
            version: "1.0.0",
            runtime: .javascript,
            entry: "missing.js",
            commands: [],
            webEntry: nil
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(throws: PluginManifestValidator.ValidationError.missingEntry) {
            _ = try validator.load(from: directory)
        }

        try Data("console.log('ready')".utf8).write(to: directory.appendingPathComponent("missing.js"))
        #expect(throws: PluginManifestValidator.ValidationError.missingCommands) {
            _ = try validator.load(from: directory)
        }
    }

    @Test("插件图标与网页入口必须保持在插件目录内")
    func pluginManifestValidatesOptionalAssets() throws {
        let directory = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("print('ready')".utf8).write(to: directory.appendingPathComponent("main.py"))
        try Data("<html></html>".utf8).write(to: directory.appendingPathComponent("index.html"))
        try Data().write(to: directory.appendingPathComponent("icon.txt"))
        let validator = PluginManifestValidator()
        let invalidIcon = PluginManifest(
            id: "com.example.assets",
            name: "Assets",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "assets", title: "Assets")],
            webEntry: "index.html",
            icon: "icon.txt"
        )

        #expect(throws: PluginManifestValidator.ValidationError.invalidIcon) {
            try validator.validate(invalidIcon, in: directory)
        }

        let missingWebEntry = PluginManifest(
            id: "com.example.missing-web-entry",
            name: "Missing Web Entry",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "missing.web", title: "Missing Web")],
            webEntry: "missing.html"
        )
        #expect(throws: PluginManifestValidator.ValidationError.missingWebEntry) {
            try validator.validate(missingWebEntry, in: directory)
        }
    }

    @Test("插件只从受管副本运行，内容变化需要重新确认")
    func pluginInstallCopiesManagedSnapshot() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "com.example.copy",
            name: "Copy",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "copy", title: "Copy")],
            webEntry: nil
        )
        try Data("print('original')".utf8).write(to: source.appendingPathComponent("main.py"))
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        try Data("vendored dependency".utf8).write(to: source.appendingPathComponent("dependency.txt"))

        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Application Support/Leap"),
            resourceDirectory: root.appendingPathComponent("Resources")
        )
        let installer = PluginInstaller(paths: paths)
        let candidate = try installer.inspect(sourceDirectory: source)
        let destination = try installer.install(candidate, confirmed: true)

        try Data("print('changed')".utf8).write(to: source.appendingPathComponent("main.py"))
        #expect(try String(contentsOf: destination.appendingPathComponent("main.py"), encoding: .utf8) == "print('original')")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("dependency.txt").path))

        let changedCandidate = try installer.inspect(sourceDirectory: source)
        #expect(installer.requiresConfirmation(for: changedCandidate))
        #expect(throws: PluginInstaller.InstallationError.confirmationRequired) {
            _ = try installer.install(changedCandidate, confirmed: false)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("main.py"), encoding: .utf8) == "print('original')")
    }

    @Test("JSON-RPC 调用校验响应和超时")
    func jsonRPCProcessRunnerValidation() throws {
        let runner = JSONRPCProcessRunner()
        let shell = URL(fileURLWithPath: "/bin/sh")
        let validScript = "read request; id=$(printf '%s' \"$request\" | sed -E 's/.*\\\"id\\\":\\\"([^\\\"]+)\\\".*/\\1/'); printf '{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":\\\"%s\\\",\\\"result\\\":\\\"ok\\\"}\\n' \"$id\""

        #expect(try runner.invoke(executable: shell, arguments: ["-c", validScript], commandID: "echo", query: "hello") == "ok")
        #expect(throws: JSONRPCProcessRunner.RunnerError.invalidResponse) {
            _ = try runner.invoke(executable: shell, arguments: ["-c", "printf 'invalid\\n'"], commandID: "echo", query: "hello")
        }
        #expect(throws: JSONRPCProcessRunner.RunnerError.timedOut) {
            _ = try runner.invoke(executable: shell, arguments: ["-c", "sleep 1"], commandID: "echo", query: "hello", timeout: 0.05)
        }
    }

    @Test("Python 与 JavaScript 示例插件使用随包运行时返回文本")
    func bundledRuntimesExecuteExamplePlugins() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = AppPaths(
            applicationSupportDirectory: projectRoot.appendingPathComponent(".test-support"),
            resourceDirectory: projectRoot.appendingPathComponent("Resources/Leap")
        )
        let executor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        let validator = PluginManifestValidator()

        let pythonDirectory = projectRoot.appendingPathComponent("Examples/Plugins/PythonEcho")
        let pythonManifest = try validator.load(from: pythonDirectory)
        #expect(try executor.invoke(manifest: pythonManifest, pluginDirectory: pythonDirectory, commandID: "python.echo", query: "测试") == "Python: python.echo / 测试")

        let javaScriptDirectory = projectRoot.appendingPathComponent("Examples/Plugins/JavaScriptEcho")
        let javaScriptManifest = try validator.load(from: javaScriptDirectory)
        #expect(try executor.invoke(manifest: javaScriptManifest, pluginDirectory: javaScriptDirectory, commandID: "javascript.echo", query: "测试") == "JavaScript: javascript.echo / 测试")

        let webDirectory = projectRoot.appendingPathComponent("Examples/Plugins/WebEcho")
        let webManifest = try validator.load(from: webDirectory)
        #expect(webManifest.webEntry == "index.html")
        #expect(try executor.invoke(manifest: webManifest, pluginDirectory: webDirectory, commandID: "web.echo", query: "来自网页") == "Web: web.echo / 来自网页")
    }

    @Test("受管插件索引只返回已信任且未变更的副本")
    func managedPluginCatalogReturnsTrustedSnapshot() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "com.example.catalog",
            name: "Catalog",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "catalog.echo", title: "Catalog Echo")]
        )
        try Data("print('ready')".utf8).write(to: source.appendingPathComponent("main.py"))
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))

        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Application Support/Leap"),
            resourceDirectory: root.appendingPathComponent("Resources")
        )
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: source), confirmed: true)
        let catalog = InstalledPluginCatalog(paths: paths)

        #expect(catalog.load().map(\.commandID) == ["catalog.echo"])
        try Data("print('changed')".utf8).write(to: try paths.managedPluginDirectory(for: manifest.id).appendingPathComponent("main.py"))
        #expect(catalog.load().isEmpty)
    }

    @Test("最近使用记录去重、限量并清理失效命令")
    func recentCommandStoreMaintainsUsableHistory() {
        let suiteName = "LeapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = RecentCommandKey(pluginID: "com.example.one", commandID: "one")
        let second = RecentCommandKey(pluginID: "com.example.two", commandID: "two")
        let store = RecentCommandStore(defaults: defaults, key: "recent", maximumCount: 2)
        store.record(first, validKeys: [first, second])
        store.record(second, validKeys: [first, second])
        store.record(first, validKeys: [first, second])

        #expect(store.load(validKeys: [first, second]) == [first, second])
        #expect(store.load(validKeys: [first]) == [first])
    }

    private func makeTemporaryPluginDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
