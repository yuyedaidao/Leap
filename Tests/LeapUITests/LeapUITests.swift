import Foundation
import LeapCore
import XCTest

final class LeapUITests: XCTestCase {
    @MainActor
    func testSearchFieldAcceptsText() {
        let app = XCUIApplication()
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.click()
        // 使用 ASCII 命令 ID，避免测试依赖当前输入法（中文输入法可能弹出额外权限提示）。
        searchField.typeText("test.echo")
        XCTAssertEqual(searchField.value as? String, "test.echo")
    }

    @MainActor
    func testHomeDoesNotShowMarketplaceOrInstalledSections() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["从这里开始"].exists)
        XCTAssertFalse(app.staticTexts["市场精选"].exists)
        XCTAssertFalse(app.staticTexts["已安装插件"].exists)
        XCTAssertFalse(app.staticTexts["最近使用"].exists)
    }

    @MainActor
    func testSystemApplicationSearchShowsCalculator() {
        let app = XCUIApplication()
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        // 用 Bundle ID 搜索，避免系统显示语言影响测试结果。
        searchField.typeText("com.apple.calculator")
        XCTAssertTrue(app.buttons["launcher.application.com.apple.calculator"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testKeyboardNavigatesSearchResultsAndRecentItems() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let sourceDirectory = supportDirectory.appendingPathComponent("KeyboardPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let pluginID = "com.padding.leap.keyboard-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID,
            name: "Keyboard Plugin",
            version: "1.0.0",
            runtime: .javascript,
            entry: "main.js",
            commands: [
                .init(id: "keyboard.first", title: "Keyboard First"),
                .init(id: "keyboard.second", title: "Keyboard Second"),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: sourceDirectory.appendingPathComponent("manifest.json"))
        let script = """
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => input += chunk);
        process.stdin.on("end", () => {
          const request = JSON.parse(input.trim());
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: request.params.commandID }) + "\\n");
        });
        """
        try Data(script.utf8).write(to: sourceDirectory.appendingPathComponent("main.js"))

        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: sourceDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("keyboard")
        XCTAssertTrue(app.buttons["launcher.command.\(pluginID)/keyboard.second"].waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["keyboard.first"].waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey("\u{7F}", modifierFlags: [])
        searchField.typeText("keyboard")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["keyboard.second"].waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey("\u{7F}", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["最近使用"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["keyboard.first"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLauncherHeightTopAnchorAndPresentationReset() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let sourceDirectory = supportDirectory.appendingPathComponent("DynamicResults", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let pluginID = "com.padding.leap.dynamic-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID,
            name: "动态结果",
            version: "1.0.0",
            runtime: .javascript,
            entry: "main.js",
            commands: (1...9).map { .init(id: "result.\($0)", title: "结果 \($0)") }
        )
        try JSONEncoder().encode(manifest).write(to: sourceDirectory.appendingPathComponent("manifest.json"))
        let script = """
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => input += chunk);
        process.stdin.on("end", () => {
          const request = JSON.parse(input.trim());
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "完成" }) + "\\n");
        });
        """
        try Data(script.utf8).write(to: sourceDirectory.appendingPathComponent("main.js"))

        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: sourceDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        // NSPanel 在 macOS 辅助功能树中是 Dialog，按稳定标识查询实际启动器。
        let window = app.dialogs["com.padding.leap.launcher"]
        let compactFrame = window.frame

        searchField.click()
        // 使用 ASCII 命令 ID，避免测试依赖当前输入法的权限状态。
        searchField.typeText("result.1")
        let firstCommand = app.buttons["launcher.command.\(pluginID)/result.1"]
        XCTAssertTrue(firstCommand.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["launcher.searchResults"].exists)

        let expandedFrame = window.frame
        XCTAssertGreaterThan(expandedFrame.height, compactFrame.height)
        // XCUITest 使用屏幕左上角坐标，minY 不变代表窗口只向下展开。
        XCTAssertEqual(expandedFrame.minY, compactFrame.minY, accuracy: 2)

        firstCommand.click()
        XCTAssertTrue(app.staticTexts["launcher.pluginResult"].waitForExistence(timeout: 5))

        app.typeKey("l", modifierFlags: [.option, .command])
        // 重新激活 Leap 后再读取状态，避免测试期间窗口焦点被系统或其他工具抢走。
        app.activate()
        let reset = expectation(
            for: NSPredicate(format: "value == ''"),
            evaluatedWith: searchField
        )
        wait(for: [reset], timeout: 5)
        XCTAssertFalse(app.staticTexts["launcher.pluginResult"].exists)
        XCTAssertTrue(app.staticTexts["最近使用"].waitForExistence(timeout: 5))

        searchField.click()
        // 本机应用索引会匹配 "a"；用独特文本检验无搜索结果时的最近使用回退。
        let unmatchedQuery = "no-match-\(UUID().uuidString)"
        searchField.typeText(unmatchedQuery)
        XCTAssertEqual(searchField.value as? String, unmatchedQuery)
        XCTAssertTrue(app.staticTexts["最近使用"].exists)
        XCTAssertTrue(firstCommand.exists)
    }

    @MainActor
    func testSettingsProvidesLocalPluginInstallation() {
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["launcher.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let pluginTab = app.buttons["插件"]
        XCTAssertTrue(pluginTab.waitForExistence(timeout: 5))
        pluginTab.click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsReopensAndPreservesSize() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapSettingsUI-\(UUID())")
        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", support.path]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        let launcher = app.dialogs["com.padding.leap.launcher"]
        let button = app.buttons["launcher.settingsButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let launcherFrame = launcher.frame
        button.click()
        let settings = app.windows["settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        let original = settings.frame
        XCTAssertTrue(original.intersects(launcherFrame), "设置应在启动器所在屏幕打开。")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.textFields["launcher.searchField"].exists, "关闭设置不应自动弹出启动器。")
        // 用原生设置快捷键重开，避免把全局启动器快捷键的焦点交接混入设置窗口回归。
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons[XCUIIdentifierCloseWindow].isHittable, "重新打开的设置窗口应位于前台并可交互。")
        XCTAssertEqual(settings.frame.width, original.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, original.height, accuracy: 2)
        XCTAssertTrue(settings.frame.intersects(launcherFrame), "复用设置窗口仍应保留屏幕归属。")
    }

    @MainActor
    func testGlobalHotKeyRestoresTheHiddenLauncher() {
        let app = XCUIApplication()
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        app.typeKey("\u{1B}", modifierFlags: [])
        let launcher = app.dialogs["com.padding.leap.launcher"]
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: launcher)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        app.typeKey("l", modifierFlags: [.option, .command])
        // 非激活 NSPanel 的 AX 类型是 Dialog，不能按普通 Window 的数量判断唤起是否成功。
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertEqual(app.dialogs.matching(identifier: "com.padding.leap.launcher").count, 1)
    }

    @MainActor
    func testWebPluginInvokesHostAndReturnsToThePage() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = projectRoot.appendingPathComponent("Examples/Plugins/WebEcho", isDirectory: true)
        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: sourceDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("Web Echo")

        let command = app.buttons["launcher.command.com.padding.leap.web-echo/web.echo"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()

        let invokeButton = app.buttons["调用 Leap"]
        XCTAssertTrue(invokeButton.waitForExistence(timeout: 5))
        invokeButton.click()
        XCTAssertTrue(app.staticTexts["Web: web.echo / 来自网页"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFailedPluginShowsAnErrorAndDoesNotBlockAnotherPlugin() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let brokenDirectory = supportDirectory.appendingPathComponent("BrokenPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let brokenManifest = PluginManifest(
            id: "com.padding.leap.broken-echo",
            name: "Broken Echo",
            version: "1.0.0",
            runtime: .javascript,
            entry: "main.js",
            commands: [.init(id: "broken.echo", title: "Broken Echo")]
        )
        try JSONEncoder().encode(brokenManifest).write(to: brokenDirectory.appendingPathComponent("manifest.json"))
        try Data("process.stdout.write('not-json\\n')".utf8).write(to: brokenDirectory.appendingPathComponent("main.js"))

        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: brokenDirectory), confirmed: true)
        let workingDirectory = projectRoot.appendingPathComponent("Examples/Plugins/JavaScriptEcho", isDirectory: true)
        try installer.install(try installer.inspect(sourceDirectory: workingDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("Broken Echo")
        let brokenCommand = app.buttons["launcher.command.com.padding.leap.broken-echo/broken.echo"]
        XCTAssertTrue(brokenCommand.waitForExistence(timeout: 5))
        brokenCommand.click()
        XCTAssertTrue(app.staticTexts["launcher.pluginError"].waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey("\u{7F}", modifierFlags: [])
        searchField.typeText("JavaScript Echo")
        let workingCommand = app.buttons["launcher.command.com.padding.leap.javascript-echo/javascript.echo"]
        XCTAssertTrue(workingCommand.waitForExistence(timeout: 5))
        workingCommand.click()
        XCTAssertTrue(app.staticTexts["JavaScript: javascript.echo / JavaScript Echo"].waitForExistence(timeout: 5))
    }
}
