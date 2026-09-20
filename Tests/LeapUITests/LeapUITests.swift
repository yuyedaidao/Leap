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
        searchField.typeText("测试")
        XCTAssertEqual(searchField.value as? String, "测试")
    }

    @MainActor
    func testHomeDoesNotShowMarketplaceOrInstalledSections() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["市场精选"].exists)
        XCTAssertFalse(app.staticTexts["已安装插件"].exists)
        XCTAssertFalse(app.staticTexts["最近使用"].exists)
    }

    @MainActor
    func testSettingsProvidesLocalPluginInstallation() {
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["launcher.settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(app.buttons["launcher.installPluginButton"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testGlobalHotKeyRestoresTheHiddenLauncher() {
        let app = XCUIApplication()
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        app.typeKey("\u{1B}", modifierFlags: [])
        app.typeKey(" ", modifierFlags: .option)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        app.typeKey(" ", modifierFlags: .option)
        XCTAssertEqual(app.windows.count, 1)
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
