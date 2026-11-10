import Foundation
import LeapCore
import XCTest

final class LauncherShellRunUITests: XCTestCase {
    @MainActor
    func testForegroundShellCommandTakesOverPanelWithOutput() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let sourceDirectory = supportDirectory.appendingPathComponent("ShellRun", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let pluginID = "com.padding.leap.shell-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID,
            name: "Shell Run",
            version: "1.0.0",
            runtime: .shell,
            entry: "run.zsh",
            commands: [.init(id: "shell.run", title: "Shell Run", executionMode: .foreground)]
        )
        try JSONEncoder().encode(manifest).write(to: sourceDirectory.appendingPathComponent("manifest.json"))
        let script = """
        #!/bin/zsh
        printf '%s\n' 'hello-from-shell'
        """
        try Data(script.utf8).write(to: sourceDirectory.appendingPathComponent("run.zsh"))

        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: sourceDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()

        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("shell")
        XCTAssertTrue(app.buttons["launcher.command.\(pluginID)/shell.run"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        // 前台 Shell 运行视图接管面板：输出可见，搜索框与搜索结果让位给插件标签。
        // 输出文本开启选择后只暴露 value，不提供 label，因此按 value 匹配。
        let output = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "hello-from-shell")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plugin.activeName"].value as? String, "Shell Run")
        XCTAssertFalse(app.textFields["launcher.searchField"].exists)
        XCTAssertFalse(app.staticTexts["搜索结果"].exists)

        app.buttons["plugin.backButton"].click()
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["plugin.activeName"].exists)
    }

    @MainActor
    func testStopButtonEndsLongRunningShell() throws {
        let app = try launchShell(
            name: "Shell Stop",
            script: """
            #!/bin/zsh
            printf 'started\\n'
            sleep 30
            """
        )
        let stop = app.buttons["launcher.stopShellButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.click()
        let finished = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "已结束")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 10))
    }

    @MainActor
    func testLongShellOutputStaysWithinCappedHeight() throws {
        let app = try launchShell(
            name: "Shell Lines",
            script: """
            #!/bin/zsh
            for i in {1..1000}; do echo "line-$i"; done
            """
        )
        let output = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@", "line-1000")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        // 输出区按文本量高最多 320 pt，其余滚动；否则千行输出会把面板顶出屏幕。
        let panel = app.dialogs["com.padding.leap.launcher"]
        XCTAssertLessThanOrEqual(panel.frame.height, 700)
    }

    /// 装一个只有一个前台命令的临时 Shell 插件、启动应用并回车执行它。
    @MainActor
    private func launchShell(name: String, script: String) throws -> XCUIApplication {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapUITests-\(UUID().uuidString)", isDirectory: true)
        // 脚本从已安装目录读取入口，删目录必须等测试结束，而不是 helper 返回。
        addTeardownBlock { try? FileManager.default.removeItem(at: supportDirectory) }

        let sourceDirectory = supportDirectory.appendingPathComponent("ShellPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let pluginID = "com.padding.leap.shell-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID,
            name: name,
            version: "1.0.0",
            runtime: .shell,
            entry: "run.zsh",
            commands: [.init(id: "shell.run", title: name, executionMode: .foreground)]
        )
        try JSONEncoder().encode(manifest).write(to: sourceDirectory.appendingPathComponent("manifest.json"))
        try Data(script.utf8).write(to: sourceDirectory.appendingPathComponent("run.zsh"))

        let paths = AppPaths(applicationSupportDirectory: supportDirectory, resourceDirectory: supportDirectory)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: sourceDirectory), confirmed: true)

        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", supportDirectory.path]
        app.launch()
        let searchField = app.textFields["launcher.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("shell")
        let command = app.buttons["launcher.command.\(pluginID)/shell.run"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        return app
    }
}
