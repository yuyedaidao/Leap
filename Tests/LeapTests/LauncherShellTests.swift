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

    @Test("Python 与 JavaScript 示例插件使用随包运行时返回文本")
    func bundledRuntimesExecuteExamplePlugins() async throws {
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
        #expect(try await executor.invoke(manifest: pythonManifest, pluginDirectory: pythonDirectory, commandID: "python.echo", query: "测试").string == "Python: python.echo / 测试")

        let javaScriptDirectory = projectRoot.appendingPathComponent("Examples/Plugins/JavaScriptEcho")
        let javaScriptManifest = try validator.load(from: javaScriptDirectory)
        #expect(try await executor.invoke(manifest: javaScriptManifest, pluginDirectory: javaScriptDirectory, commandID: "javascript.echo", query: "测试").string == "JavaScript: javascript.echo / 测试")

        let webDirectory = projectRoot.appendingPathComponent("Examples/Plugins/WebEcho")
        let webManifest = try validator.load(from: webDirectory)
        #expect(webManifest.webEntry == "index.html")
        #expect(try await executor.invoke(manifest: webManifest, pluginDirectory: webDirectory, commandID: "web.echo", query: "来自网页").string == "Web: web.echo / 来自网页")

        let shellDirectory = projectRoot.appendingPathComponent("Examples/Plugins/ShellCommands")
        let shellManifest = try validator.load(from: shellDirectory)
        #expect(shellManifest.runtime == .shell)
        #expect(shellManifest.commands.map(\.resolvedExecutionMode) == [.foreground, .background])
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

        #expect(catalog.loadPlugins().map(\.manifest.id) == [manifest.id])
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

    @Test("系统应用索引支持名称、拼音首字母、缓存和重复 Bundle ID 优先级")
    func systemApplicationIndexSearchAndCache() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let userApplications = root.appendingPathComponent("User", isDirectory: true)
        let globalApplications = root.appendingPathComponent("Global", isDirectory: true)
        let userCalculator = try makeApplication(named: "计算器", bundleID: "com.example.calculator", in: userApplications)
        _ = try makeApplication(named: "Calculator Old", bundleID: "com.example.calculator", in: globalApplications)
        _ = try makeApplication(named: "后台工具", bundleID: "com.example.background", in: globalApplications, backgroundOnly: true)

        let applications = SystemApplicationScanner(roots: [userApplications, globalApplications]).scan()
        #expect(applications.count == 1)
        #expect(applications.first?.path == userCalculator.path)
        #expect(applications.first?.matchRank(for: "jsq") != nil)
        #expect(applications.first?.matchRank(for: "calculator") != nil)

        let cacheURL = root.appendingPathComponent("index.json")
        try SystemApplicationIndexCache.save(applications, to: cacheURL)
        #expect(SystemApplicationIndexCache.load(from: cacheURL) == applications)
        try Data(#"{"version":2,"applications":[]}"#.utf8).write(to: cacheURL)
        #expect(SystemApplicationIndexCache.load(from: cacheURL) == nil)
        try Data("not-json".utf8).write(to: cacheURL)
        #expect(SystemApplicationIndexCache.load(from: cacheURL) == nil)
    }

    @Test("扫描器索引应用包内的本地化名称")
    func systemApplicationScannerIndexesLocalizedName() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(
            named: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            in: root,
            localizedName: "微信"
        )

        let application = SystemApplicationScanner(
            roots: [root],
            preferredLanguages: ["zh-Hans"]
        ).scan().first

        #expect(application?.name == "微信")
        #expect(application?.matchRank(for: "微信") == 0)
        #expect(application?.matchRank(for: "WeChat") == 0)
    }

    @Test("统一使用记录迁移旧插件历史并移除失效项目")
    func launcherUsageStoreMigratesAndFiltersHistory() throws {
        let suiteName = "LeapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let command = RecentCommandKey(pluginID: "com.example.echo", commandID: "echo")
        defaults.set(try JSONEncoder().encode([command]), forKey: "legacy")
        let key = LauncherUsageKey.plugin(command)
        let store = LauncherUsageStore(defaults: defaults, key: "usage", legacyKey: "legacy", maximumCount: 2)

        #expect(store.load(validKeys: [key]).map(\.key) == [key])
        store.record(.application(path: "/Applications/Calculator.app"), validKeys: [key, .application(path: "/Applications/Calculator.app")])
        #expect(store.load(validKeys: [.application(path: "/Applications/Calculator.app")]).map(\.key) == [.application(path: "/Applications/Calculator.app")])
        store.clear()
        #expect(store.load(validKeys: [.application(path: "/Applications/Calculator.app")]).isEmpty)
    }

    @Test("卸载受管插件会删除副本和信任记录")
    func pluginUninstallRemovesManagedFilesAndTrust() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "com.example.remove",
            name: "Remove",
            version: "1.0.0",
            runtime: .python,
            entry: "main.py",
            commands: [.init(id: "remove", title: "Remove")]
        )
        try Data("print('ready')".utf8).write(to: source.appendingPathComponent("main.py"))
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))

        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Application Support/Leap"),
            resourceDirectory: root.appendingPathComponent("Resources")
        )
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: source), confirmed: true)
        try installer.uninstall(pluginID: manifest.id)

        #expect(!FileManager.default.fileExists(atPath: try paths.managedPluginDirectory(for: manifest.id).path))
        #expect(!FileManager.default.fileExists(atPath: try paths.trustRecordURL(for: manifest.id).path))
        #expect(InstalledPluginCatalog(paths: paths).loadPlugins().isEmpty)
    }

    private func makeTemporaryPluginDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeApplication(
        named name: String,
        bundleID: String,
        in directory: URL,
        backgroundOnly: Bool = false,
        localizedName: String? = nil
    ) throws -> URL {
        let application = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Runner")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var info: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Runner",
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name
        ]
        if backgroundOnly { info["LSBackgroundOnly"] = true }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if let localizedName {
            let localizedDirectory = contents.appendingPathComponent("Resources/zh-Hans.lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: localizedDirectory, withIntermediateDirectories: true)
            let localizedInfo = "\"CFBundleDisplayName\" = \"\(localizedName)\";"
            try Data(localizedInfo.utf8).write(to: localizedDirectory.appendingPathComponent("InfoPlist.strings"))
        }
        return application
    }
}

struct ShellScriptExecutorTests {
    @Test("Shell 插件支持命令级前后台模式和流式输出")
    func shellPluginExecutionModesAndOutput() throws {
        let directory = try makeTemporaryShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryURL = directory.appendingPathComponent("run.zsh")
        try Data("print -r -- \"$LEAP_COMMAND_ID:$PWD\"\nprint -u2 -- stderr".utf8).write(to: entryURL)

        let legacyManifest = Data(#"""
        {"id":"com.example.shell","name":"Shell","version":"1.0.0","runtime":"shell","entry":"run.zsh","commands":[{"id":"shell.run","title":"Shell Run"}]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: legacyManifest)
        #expect(manifest.commands.first?.resolvedExecutionMode == .foreground)

        let task = try ShellScriptExecutor().makeForegroundTask(
            entryURL: entryURL,
            pluginDirectory: directory,
            commandID: "shell.run"
        )
        let output = OutputCollector()
        let collectOutput: @Sendable (String) -> Void = { output.append($0) }
        try task.start(onOutput: collectOutput)
        try task.waitForCompletion(onOutput: collectOutput)

        let capturedOutput = output.value
        #expect(capturedOutput.contains("shell.run:"))
        #expect(capturedOutput.contains(directory.lastPathComponent))
        #expect(capturedOutput.contains("stderr"))
    }

    @Test("Shell 后台任务不等待脚本结束")
    func shellPluginBackgroundTaskStartsWithoutBlocking() throws {
        let directory = try makeTemporaryShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryURL = directory.appendingPathComponent("background.zsh")
        let markerURL = directory.appendingPathComponent("completed")
        try Data("sleep 0.1\nprint done > completed".utf8).write(to: entryURL)

        try ShellScriptExecutor().startBackground(
            entryURL: entryURL,
            pluginDirectory: directory,
            commandID: "shell.background"
        )
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        Thread.sleep(forTimeInterval: 0.2)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Shell 前台任务可停止")
    func shellPluginForegroundTaskCanStop() async throws {
        let directory = try makeTemporaryShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryURL = directory.appendingPathComponent("wait.zsh")
        try Data("print -r -- started\nsleep 5".utf8).write(to: entryURL)
        let task = try ShellScriptExecutor().makeForegroundTask(
            entryURL: entryURL,
            pluginDirectory: directory,
            commandID: "shell.wait"
        )
        try task.start(onOutput: { _ in })
        let completion = Task.detached { Result { try task.waitForCompletion(onOutput: { _ in }) } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await completion.value
        #expect(throws: ShellScriptError.cancelled) { try result.get() }
    }
}

struct SystemApplicationDescriptorTests {
    @Test("系统应用同时匹配本地化和原始名称")
    func systemApplicationSearchMatchesLocalizedAndOriginalName() {
        let application = SystemApplicationDescriptor(
            name: "微信",
            bundleIdentifier: "com.tencent.xinWeChat",
            url: URL(fileURLWithPath: "/Applications/WeChat.app"),
            alternateNames: ["WeChat"]
        )

        #expect(application.matchRank(for: "微信") == 0)
        #expect(application.matchRank(for: "WeChat") == 0)
        #expect(application.matchRank(for: "weixin") != nil)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ chunk: String) {
        lock.lock()
        output += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

private func makeTemporaryShellDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LeapShellTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
