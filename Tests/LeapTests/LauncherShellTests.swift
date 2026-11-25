import Foundation
import Testing
@testable import LeapCore

// 临时应用包夹具被多个测试类型共用，放在文件作用域而不是撑大某个测试类型。
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
    localizedName: String? = nil,
    localizedTable: [String: Any]? = nil,
    isSymbolicLink: Bool = false,
    packageType: String? = "APPL",
    infoExtra: [String: Any] = [:]
) throws -> URL {
    // 符号链接形态：真实应用藏在隐藏目录里，仅通过一个隐藏符号链接暴露（Safari 的挂载方式）。
    let container = isSymbolicLink
        ? directory.appendingPathComponent(".Targets", isDirectory: true) : directory
    let application = try makeBundle(
        named: name, bundleID: bundleID, in: container,
        backgroundOnly: backgroundOnly, localizedName: localizedName, localizedTable: localizedTable,
        packageType: packageType, infoExtra: infoExtra
    )
    guard isSymbolicLink else { return application }
    let link = directory.appendingPathComponent("\(name).app", isDirectory: true)
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: ".Targets/\(name).app"
    )
    for path in [link, container] {
        try setHiddenFlag(at: path)
        // 自检：真实形态是 flag 在符号链接自身，不在目标上；打不上就失去回归价值。
        #expect(isHiddenResourceValue(path))
    }
    return link
}

private func makeBundle(
    named name: String,
    bundleID: String,
    in directory: URL,
    backgroundOnly: Bool,
    localizedName: String?,
    localizedTable: [String: Any]?,
    packageType: String? = "APPL",
    infoExtra: [String: Any] = [:]
) throws -> URL {
    let application = directory.appendingPathComponent("\(name).app", isDirectory: true)
    let contents = application.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("Runner")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var info: [String: Any] = [
        "CFBundleExecutable": "Runner",
        "CFBundleIdentifier": bundleID,
        "CFBundleName": name
    ]
    // nil 复现只缺包类型的系统件（CoreServicesUIAgent 之类）。
    if let packageType { info["CFBundlePackageType"] = packageType }
    if backgroundOnly { info["LSBackgroundOnly"] = true }
    // 包名与包内名称不一致的真实形态（Xcode-27.2.0.app 的 CFBundleName 是 Xcode）。
    info.merge(infoExtra) { _, extra in extra }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    if let localizedName {
        let localizedDirectory = contents.appendingPathComponent("Resources/zh-Hans.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localizedDirectory, withIntermediateDirectories: true)
        let localizedInfo = "\"CFBundleDisplayName\" = \"\(localizedName)\";"
        try Data(localizedInfo.utf8).write(to: localizedDirectory.appendingPathComponent("InfoPlist.strings"))
    }
    if let localizedTable {
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let tableData = try PropertyListSerialization.data(
            fromPropertyList: localizedTable, format: .binary, options: 0
        )
        try tableData.write(to: resources.appendingPathComponent("InfoPlist.loctable"))
    }
    return application
}

/// Foundation 没有暴露 UF_HIDDEN，借助 chflags 让测试目录复现真实挂载形态。
/// 必须带 -h：不带时 chflags 会跟随符号链接，flag 落到目标上（Safari 的 flag 在链接自身）。
private func setHiddenFlag(at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    process.arguments = ["-h", "hidden", url.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func isHiddenResourceValue(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
}

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
        for version in [2, 3, 4, 5, 6, 7, 8] {
            try Data("{\"version\":\(version),\"applications\":[]}".utf8).write(to: cacheURL)
            #expect(SystemApplicationIndexCache.load(from: cacheURL) == nil)
        }
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
        // 别名回退：Bundle ID 包含 wechat，本名兜底梯队里标识命中优先。
        #expect(application?.matchRank(for: "WeChat") == SearchMatchRank.identifierContains.rawValue)
    }

    @Test("隐藏符号链接形态的应用仍会被索引")
    func systemApplicationScannerIndexesHiddenSymbolicLink() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Safari 就是这种形态：/Applications/Safari.app 是带 hidden 标志的符号链接，指向隐藏目录。
        _ = try makeApplication(
            named: "Safari",
            bundleID: "com.apple.Safari",
            in: root,
            isSymbolicLink: true
        )

        let applications = SystemApplicationScanner(roots: [root]).scan()

        #expect(applications.map(\.bundleIdentifier) == ["com.apple.Safari"])
        #expect(applications.first?.matchRank(for: "safari") == 0)
    }

    @Test("包类型不是 APPL 的系统应用（访达、密码）仍会被索引")
    func systemApplicationScannerIgnoresPackageType() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // 访达是 FNDR、密码是 XPC!，部分系统件干脆不写 CFBundlePackageType。
        _ = try makeApplication(
            named: "Finder",
            bundleID: "com.apple.finder",
            in: root,
            localizedTable: ["zh_CN": ["CFBundleDisplayName": "访达"]],
            packageType: "FNDR"
        )
        _ = try makeApplication(
            named: "Passwords", bundleID: "com.apple.Passwords", in: root, packageType: "XPC!"
        )
        _ = try makeApplication(
            named: "WiFiAgent", bundleID: "com.apple.wifi.WiFiAgent", in: root, packageType: nil
        )
        // 后台件仍必须排除，不能连 LSBackgroundOnly 一起放宽。
        _ = try makeApplication(
            named: "Claude Code URL Handler",
            bundleID: "com.example.background",
            in: root,
            backgroundOnly: true
        )

        let applications = SystemApplicationScanner(roots: [root], preferredLanguages: ["zh-Hans"]).scan()

        let identifiers = Set(applications.map(\.bundleIdentifier))
        #expect(identifiers == ["com.apple.Passwords", "com.apple.finder", "com.apple.wifi.WiFiAgent"])
        let finder = try #require(applications.first { $0.bundleIdentifier == "com.apple.finder" })
        #expect(finder.name == "访达")
        #expect(finder.matchRank(for: "访达") == 0)
        #expect(finder.matchRank(for: "finder") == SearchMatchRank.identifierContains.rawValue)
    }

    @Test("统一使用记录迁移旧插件历史，清理只在显式调用时发生")
    func launcherUsageStoreMigratesAndFiltersHistory() throws {
        let suiteName = "LeapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let command = RecentCommandKey(pluginID: "com.example.echo", commandID: "echo")
        defaults.set(try JSONEncoder().encode([command]), forKey: "legacy")
        let key = LauncherUsageKey.plugin(command)
        let applicationKey = LauncherUsageKey.application(path: "/Applications/Calculator.app")
        let store = LauncherUsageStore(defaults: defaults, key: "usage", legacyKey: "legacy", maximumCount: 2)

        #expect(store.load().map(\.key) == [key])
        store.record(applicationKey)
        // 插件目录与应用索引加载有先后，读取与记录都不能把另一侧尚未加载的记录当作已卸载。
        #expect(store.load().map(\.key) == [applicationKey, key])

        store.prune(keeping: [applicationKey])
        #expect(store.load().map(\.key) == [applicationKey])
        store.clear()
        #expect(store.load().isEmpty)
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
}

extension LauncherShellTests {
    @Test("系统工具 loctable 支持中文、英文别名及拼音检索", arguments: [
        ("Activity Monitor", "活动监视器", "huodongjianshiqi", "hdjsq"),
        ("Disk Utility", "磁盘工具", "cipangongju", "cpgj")
    ])
    func systemApplicationScannerIndexesLocalizationTable(
        originalName: String, localizedName: String, pinyin: String, initials: String
    ) throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(
            named: originalName,
            bundleID: "com.example.tool",
            in: root,
            localizedTable: [
                "zh_CN": ["CFBundleDisplayName": localizedName, "CFBundleName": localizedName],
                "en": ["CFBundleName": originalName],
                // 元数据即使包含同名字段，也不能参与语言选择或搜索。
                "LocProvenance": ["CFBundleName": "索引元数据"]
            ]
        )

        let application = try #require(SystemApplicationScanner(
            roots: [root], preferredLanguages: ["zh-Hans-CN"]
        ).scan().first)
        #expect(application.name == localizedName)
        // 显示名与检索名一致（都是中文名），无需额外字段。
        #expect(application.displayName == nil)
        #expect(application.matchRank(for: localizedName) == 0)
        #expect(application.matchRank(for: String(localizedName.prefix(2))) == 1)
        #expect(application.matchRank(for: String(localizedName.suffix(2))) == 2)
        // 非首选语言的 CFBundleName 只在没有本名命中时兜底。
        #expect(application.matchRank(for: originalName) == SearchMatchRank.aliasOffset)
        #expect(application.matchRank(for: pinyin) != nil)
        #expect(application.matchRank(for: initials) != nil)
        #expect(application.alternateNames == [originalName])
        #expect(application.matchRank(for: "索引元数据") == nil)

        let englishApplication = try #require(SystemApplicationScanner(
            roots: [root], preferredLanguages: ["en"]
        ).scan().first)
        #expect(englishApplication.name == originalName)
        #expect(englishApplication.matchRank(for: localizedName) == SearchMatchRank.aliasOffset)
    }

    @Test("同语言 strings 名称优先，loctable 补充检索别名")
    func systemApplicationScannerPreservesStringsPriority() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(
            named: "Utility",
            bundleID: "com.example.utility",
            in: root,
            localizedName: "旧名称",
            localizedTable: ["zh-Hans": ["CFBundleDisplayName": "新名称", "CFBundleName": "旧名称"]]
        )

        let application = try #require(SystemApplicationScanner(
            roots: [root], preferredLanguages: ["zh-Hans"]
        ).scan().first)
        #expect(application.name == "旧名称")
        #expect(application.displayName == nil)
        #expect(application.alternateNames == ["Utility", "新名称"])
        // loctable 里的同语言别名同样是别名，只做本名之外的回退。
        #expect(application.matchRank(for: "新名称") == SearchMatchRank.aliasOffset)
    }

    @Test("无效 loctable 不影响应用收录和原始名称回退")
    func systemApplicationScannerIgnoresInvalidLocalizationTables() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidResources = [
            Data("not a property list".utf8),
            try PropertyListSerialization.data(fromPropertyList: ["invalid root"], format: .binary, options: 0),
            try PropertyListSerialization.data(fromPropertyList: [
                "zh_CN": ["CFBundleName": 42, "CFBundleDisplayName": true],
                "zh_TW": ["CFBundleName": " \n"],
                "en": "invalid language entry"
            ], format: .binary, options: 0)
        ]
        for (index, resource) in invalidResources.enumerated() {
            let name = "Fallback\(index)"
            let applicationURL = try makeApplication(
                named: name,
                bundleID: "com.example.fallback\(index)",
                in: root,
                localizedTable: [:]
            )
            try resource.write(to: applicationURL.appendingPathComponent("Contents/Resources/InfoPlist.loctable"))
        }

        let applications = SystemApplicationScanner(roots: [root], preferredLanguages: ["zh-Hans-CN"]).scan()
        #expect(applications.map(\.name) == ["Fallback0", "Fallback1", "Fallback2"])
        #expect(applications.allSatisfy { $0.matchRank(for: $0.name) == 0 })
    }

    @Test("非首选语言的罗马化别名不再命中首字母查询")
    func systemApplicationScannerIgnoresTransliteratedAliases() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(
            named: "Preview",
            bundleID: "com.apple.Preview",
            in: root,
            localizedName: "预览",
            localizedTable: ["th": ["CFBundleDisplayName": "แสดงตัวอย่าง"]]
        )

        let application = try #require(
            SystemApplicationScanner(roots: [root], preferredLanguages: ["zh-Hans"]).scan().first
        )

        #expect(application.name == "预览")
        #expect(application.alternateNames.contains("แสดงตัวอย่าง"))
        // 泰语名的罗马化含 wx，不能因此把「预览」推到「微信」前面。
        #expect(application.matchRank(for: "wx") == nil)
        #expect(application.matchRank(for: "แสดงตัวอย่าง") == SearchMatchRank.aliasOffset)
    }

    @Test("同一目录下同 Bundle ID 的多份副本都保留，且标识唯一")
    func systemApplicationScannerKeepsSameBundleIDCopies() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // 复现真实形态：包名带版本，包内名称都是 Xcode。
        let first = try makeApplication(
            named: "Xcode-27.2.0", bundleID: "com.apple.dt.Xcode", in: root, infoExtra: ["CFBundleName": "Xcode"]
        )
        let second = try makeApplication(
            named: "Xcode-26.6.0", bundleID: "com.apple.dt.Xcode", in: root, infoExtra: ["CFBundleName": "Xcode"]
        )

        let applications = SystemApplicationScanner(roots: [root]).scan()

        #expect(applications.count == 2)
        // 结果列表按 id 索引选中与滚动，重复 id 会让第二份不可选。
        #expect(Set(applications.map(\.id)).count == 2)
        #expect(
            Set(applications.map(\.path))
                == Set([first, second].map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        )
        // 没有本地化名时标题用包名，两份副本才能区分；检索名仍是 Xcode。
        #expect(applications.map(\.name) == ["Xcode", "Xcode"])
        #expect(Set(applications.compactMap(\.displayName)) == ["Xcode-27.2.0", "Xcode-26.6.0"])
        #expect(applications.allSatisfy { $0.matchRank(for: "xcode") == 0 })
    }

    @Test("取不到系统语言时沿用包内语言顺序，标题不回退成包名")
    func systemApplicationScannerWithoutPreferredLanguages() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(named: "Calculator", bundleID: "com.apple.calculator", in: root, localizedName: "计算器")

        let application = try #require(SystemApplicationScanner(
            roots: [root], preferredLanguages: []
        ).scan().first)
        #expect(application.name == "计算器")
        #expect(application.displayName == nil)
    }

    @Test("空的 CFBundleDisplayName 不当名称用")
    func systemApplicationScannerIgnoresEmptyDisplayName() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Copilot for Xcode 的 CFBundleDisplayName 是空串而不是缺失。
        _ = try makeApplication(
            named: "Copilot for Xcode",
            bundleID: "com.intii.CopilotForXcode",
            in: root,
            infoExtra: ["CFBundleDisplayName": ""]
        )

        let application = try #require(SystemApplicationScanner(roots: [root]).scan().first)
        #expect(application.name == "Copilot for Xcode")
        #expect(application.displayName == nil)
    }

    @Test("本地化文件没有名称键时标题回退到包名")
    func systemApplicationScannerDisplayNameFallsBackToPackage() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // VS Code 的分发形态：CFBundleName 是 Code，zh_CN.lproj 存在但不含名称键。
        _ = try makeApplication(
            named: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            in: root,
            localizedTable: ["zh_CN": ["CFBundleExecutable": "Electron"]],
            infoExtra: ["CFBundleName": "Code"]
        )

        let application = try #require(SystemApplicationScanner(
            roots: [root], preferredLanguages: ["zh-Hans-CN"]
        ).scan().first)
        #expect(application.name == "Code")
        #expect(application.displayName == "Visual Studio Code")
        // 检索用短名，不受显示影响。
        #expect(application.matchRank(for: "code") == 0)
    }

    @Test("同一目录内的可见符号链接与目标只索引一次")
    func systemApplicationScannerDeduplicatesPathsWithinRoot() throws {
        let root = try makeTemporaryPluginDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApplication(named: "Real", bundleID: "com.example.real", in: root)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Link.app").path, withDestinationPath: "Real.app"
        )

        #expect(SystemApplicationScanner(roots: [root]).scan().count == 1)
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
        // 别名只做兜底：这里 Bundle ID 包含 wechat，标识命中仍在别名之前。
        #expect(application.matchRank(for: "WeChat") == SearchMatchRank.identifierContains.rawValue)
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
