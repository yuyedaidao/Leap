import Foundation
import LeapCore
import XCTest

final class PluginInteractionUITests: XCTestCase {
    @MainActor
    func testKeywordEntryContinuousInputSelectionAndContentEntry() throws {
        let app = try launch(source: "TextConvert")
        let search = app.textFields["launcher.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["launcher.settingsButton"].exists)
        search.click()
        search.typeText("convert")
        XCTAssertEqual(search.value as? String, "convert")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(parameter.value as? String, "")
        XCTAssertFalse(search.exists)
        XCTAssertTrue(app.buttons["launcher.settingsButton"].exists)
        XCTAssertEqual(app.staticTexts["plugin.activeName"].value as? String, "文本转换")
        XCTAssertFalse(app.staticTexts["plugin.activeTitle"].exists)
        parameter.typeText("Hello")
        let upper = app.buttons["plugin.result.upper"]
        XCTAssertTrue(upper.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(upper.label.contains("HELLO"))
        parameter.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        parameter.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let feedback = app.staticTexts["plugin.listFeedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.value as? String ?? feedback.label, "hello")
        // 不重新点击参数框，验证选择反馈后可直接继续键入并刷新列表。
        parameter.typeText("!")
        let continued = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "HELLO!"), object: upper
        )
        XCTAssertEqual(XCTWaiter.wait(for: [continued], timeout: 5), .completed)
        parameter.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "convert")

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("World")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        XCTAssertEqual(parameter.value as? String, "World")
        let converted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "WORLD"), object: upper
        )
        XCTAssertEqual(XCTWaiter.wait(for: [converted], timeout: 5), .completed)
        app.buttons["plugin.backButton"].click()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "World")
        // 原生输入框重新聚焦时会选中文字；移到末尾后验证无需点击即可继续输入。
        search.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        search.typeText("!")
        XCTAssertEqual(search.value as? String, "World!")
    }

    @MainActor
    func testLongPluginTagPreservesInputSpace() throws {
        let name = "用于验证插件标签截断且不挤压输入框的很长插件名称"
        let app = try launch(source: "TextConvert", pluginName: name, openPlugin: true)
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["plugin.activeName"].value as? String, name)
        XCTAssertEqual(app.staticTexts["plugin.activeTitle"].value as? String, "文本转换")
        XCTAssertGreaterThan(parameter.frame.width, 300)
        let plugin = XCTAttachment(screenshot: app.screenshot())
        plugin.name = "插件前缀与原设置按钮"
        plugin.lifetime = .keepAlways
        add(plugin)
        let settings = app.buttons["launcher.settingsButton"]
        XCTAssertTrue(settings.exists)
        XCTAssertLessThan(parameter.frame.maxX, settings.frame.minX)
        parameter.typeText("Hello")
        XCTAssertEqual(parameter.value as? String, "Hello")
        app.buttons["plugin.backButton"].click()
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
        let normal = XCTAttachment(screenshot: app.screenshot())
        normal.name = "普通搜索栏"
        normal.lifetime = .keepAlways
        add(normal)
    }

    @MainActor
    func testDisabledInputKeepsPluginTagAndExit() throws {
        let app = try launch(source: "WebEcho", events: true, inputEnabled: false)
        XCTAssertTrue(app.buttons["plugin.backButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["plugin.activeName"].exists)
        XCTAssertFalse(app.textFields["plugin.parameterInput"].exists)
        XCTAssertTrue(app.buttons["launcher.settingsButton"].exists)
        app.buttons["plugin.backButton"].click()
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPluginSettingsButtonOpensSettings() throws {
        let app = try launch(source: "WebEcho", events: true)
        XCTAssertTrue(app.textFields["plugin.parameterInput"].waitForExistence(timeout: 5))
        let settings = app.buttons["launcher.settingsButton"]
        XCTAssertTrue(settings.exists)
        settings.click()
        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["plugin.backButton"].exists)
    }

    @MainActor
    func testExplicitActionDoesNotOpenSharedWebEntry() throws {
        let app = try launch(source: "WebEcho", action: true)
        XCTAssertTrue(app.staticTexts["launcher.pluginResult"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.windows["plugin.webWindow"].exists)
        XCTAssertFalse(app.buttons["plugin.backButton"].exists)
    }

    @MainActor
    func testEmbeddedWebReceivesInitialInputChangesAndSubmit() throws {
        let app = try launch(source: "WebEcho", events: true)
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entered web.echo"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(parameter.frame.minX, app.buttons["plugin.backButton"].frame.maxX)
        parameter.click()
        parameter.typeText("Hello")
        XCTAssertTrue(app.staticTexts["input Hello"].waitForExistence(timeout: 5))
        parameter.typeKey("a", modifierFlags: .command)
        parameter.typeText("中文参数")
        XCTAssertEqual(parameter.value as? String, "中文参数")
        XCTAssertTrue(app.staticTexts["input 中文参数"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["submit 中文参数"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.windows["plugin.webWindow"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(
        source: String, action: Bool = false, events: Bool = false,
        pluginName: String? = nil, inputEnabled: Bool = true, openPlugin: Bool = false
    ) throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapInteractionUI-\(UUID())")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: project.appendingPathComponent("Examples/Plugins/\(source)"), to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if action || events || pluginName != nil {
            let data = try Data(contentsOf: manifestURL)
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let commands = try XCTUnwrap(manifest["commands"] as? [[String: Any]])
            var command = try XCTUnwrap(commands.first)
            command["mode"] = action ? "action" : "interactive"
            if let pluginName { manifest["name"] = pluginName }
            if events {
                command["presentation"] = "web"
                command["input"] = ["enabled": inputEnabled]
                let html = """
                <!doctype html><html lang="zh-CN"><body>
                <p id="enter"></p><p id="input"></p><p id="submit"></p>
                <script>
                window.leap.onEnter(value => document.getElementById('enter').textContent = 'entered ' + value.commandID);
                window.leap.onInputChange(value => document.getElementById('input').textContent = 'input ' + value);
                window.leap.onSubmit(value => document.getElementById('submit').textContent = 'submit ' + value);
                </script></body></html>
                """
                try Data(html.utf8).write(to: directory.appendingPathComponent("index.html"))
            }
            manifest["commands"] = [command]
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        }
        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("Support"), resourceDirectory: root)
        let installer = PluginInstaller(paths: paths)
        let candidate = try installer.inspect(sourceDirectory: directory)
        try installer.install(candidate, confirmed: true)
        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", paths.applicationSupportDirectory.path]
        if action || events || openPlugin { app.launchArguments += ["-leap-testing-open-plugin", candidate.manifest.id] }
        addTeardownBlock {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            self.add(tree)
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        app.activate()
        return app
    }
}
