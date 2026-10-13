import Foundation
import LeapCore
import XCTest

final class PluginDetailsUITests: XCTestCase {
    private let longKeyword = String(repeating: "long-keyword-", count: 16)

    @MainActor
    func testDetailsSelectionSurvivesCategoryChangesAndReopening() {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDetailsUI-\(UUID())")
        let app = launch(support: support)
        app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings.section.general"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.launchAtLoginToggle"].firstMatch.exists)
        app.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.installPluginButton"].exists)

        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let original = settings.frame
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.frame, original)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        app.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDetailsShowKeywordsRulesAndLegacyModes() throws {
        let fixture = try makeFixture()
        let app = launch(support: fixture.support)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let originalFrame = settings.frame
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        let scroll = app.scrollViews["settings.pluginDetails.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertEqual(settings.frame, originalFrame)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)

        let keywords = app.staticTexts["settings.pluginCommand.first.keywords"]
        XCTAssertTrue(keywords.waitForExistence(timeout: 5))
        XCTAssertEqual(keywords.value as? String, "alpha、shared、\(longKeyword)")
        XCTAssertGreaterThan(keywords.frame.height, 20, "长关键字应换行，不能截断。")
        XCTAssertTrue(app.staticTexts["动作 · 后台执行"].exists)
        let defaultLimits = "\(1.formatted())–\(1000.formatted())"
        XCTAssertTrue(app.staticTexts["文本匹配 · \(defaultLimits) 个字符"].exists)
        XCTAssertTrue(app.staticTexts["正则匹配 · 3–32 个字符"].exists)
        XCTAssertTrue(app.staticTexts["^leap-[0-9]+$"].exists)

        let secondKeywords = app.staticTexts["settings.pluginCommand.second.keywords"]
        scrollTo(secondKeywords, in: scroll)
        XCTAssertEqual(secondKeywords.value as? String, "beta、shared", "不同命令的关键字应分别展示。")
        XCTAssertTrue(app.staticTexts["内嵌列表交互"].exists)
        XCTAssertTrue(app.staticTexts["输入参数"].exists)
        let legacy = app.staticTexts["settings.pluginCommand.legacy.behavior"]
        scrollTo(legacy, in: scroll)
        XCTAssertEqual(legacy.value as? String, "独立网页窗口")
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.legacy.keywords"].value as? String, "未声明额外关键字")
        let action = app.staticTexts["settings.pluginCommand.action.behavior"]
        scrollTo(action, in: scroll)
        XCTAssertEqual(action.value as? String, "动作 · 等待完成")
        XCTAssertTrue(app.staticTexts["未声明内容匹配规则"].exists)

        let technical = app.descendants(matching: .any)["settings.pluginDetails.technical"].firstMatch
        scrollTo(technical, in: scroll)
        XCTAssertFalse(app.staticTexts[fixture.id].isHittable, "技术信息应默认折叠。")
        technical.click()
        scrollTo(app.staticTexts[fixture.id], in: scroll)
        XCTAssertTrue(app.staticTexts[fixture.id].isHittable)
        XCTAssertTrue(app.staticTexts["javascript"].exists)
        XCTAssertTrue(app.staticTexts["main.js"].exists)
        XCTAssertTrue(app.staticTexts["未声明"].exists, "旧清单未提供最低宿主版本时应显示缺省状态。")
        app.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.\(fixture.id)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.installPluginButton"].exists)
        XCTAssertEqual(settings.frame, originalFrame)
    }

    @MainActor
    func testOfficialPluginDetailsKeepManagementRestrictions() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDetailsUI-\(UUID())")
        let app = launch(support: support)
        app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["官方内置"].exists)
        XCTAssertFalse(app.buttons["更新"].exists)
        XCTAssertFalse(app.buttons["卸载"].exists)
        XCTAssertEqual(
            app.staticTexts["settings.pluginCommand.template.generate.keywords"].value as? String,
            "创建插件、插件模板"
        )
        XCTAssertTrue(app.staticTexts["内嵌网页交互"].exists)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "官方插件详情"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testUpdatingDetailsReadsLatestManifestAndUninstallReturnsToList() throws {
        let fixture = try makeFixture()
        let updated = fixture.support.appendingPathComponent("UpdatedSource")
        let manifest = PluginManifest(
            id: fixture.id, name: "Details Plugin", version: "2.0.0", runtime: .javascript, entry: "main.js",
            commands: [.init(id: "first", title: "Updated Command", keywords: ["updated-keyword"])]
        )
        try writePlugin(manifest, to: updated)
        let app = launch(support: fixture.support)
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        app.activate()
        app.buttons["更新"].click()
        try choosePluginDirectory(updated, in: app)
        // SwiftUI 同时暴露不可见的确认动作，定位实际系统 sheet 中的按钮。
        let install = app.sheets.buttons["安装 Details Plugin"]
        XCTAssertTrue(install.waitForExistence(timeout: 5), app.debugDescription)
        install.click()
        let version = app.staticTexts["settings.pluginDetails.version"]
        let refreshed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS '2.0.0'"), object: version
        )
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].exists)
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.first.keywords"].value as? String, "updated-keyword")
        XCTAssertTrue(app.staticTexts["Updated Command"].exists)
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.first.behavior"].value as? String, "动作 · 等待完成")

        app.buttons["卸载"].click()
        let confirm = app.sheets.buttons["卸载 Details Plugin"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.pluginDetails.back"].exists)
        XCTAssertFalse(app.buttons["settings.pluginDetails.\(fixture.id)"].exists)
        // 卸载仅清理受管副本，测试的更新源目录必须仍在。
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    private func launch(support: URL) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", support.path]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        XCTAssertTrue(app.buttons["launcher.settingsButton"].waitForExistence(timeout: 5))
        app.buttons["launcher.settingsButton"].click()
        // 原生非激活面板需要让 XCUITest 明确绑定 Leap，避免误取后台应用的控件。
        app.activate()
        let tab = app.descendants(matching: .any)["settings.section.plugins"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        return app
    }

    private func makeFixture() throws -> (support: URL, id: String) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDetailsUI-\(UUID())")
        let pluginID = "com.padding.leap.details-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID, name: "Details Plugin", version: "1.0.0", runtime: .javascript, entry: "main.js",
            commands: [
                .init(id: "first", title: "First Command", executionMode: .background, mode: .action,
                      keywords: ["alpha", "shared", longKeyword],
                      matches: [.init(type: .text), .init(type: .regex, pattern: "^leap-[0-9]+$",
                                                        minLength: 3, maxLength: 32)]),
                .init(id: "second", title: "Second Command", mode: .interactive, presentation: .list,
                      keywords: ["beta", "shared"], input: .init(placeholder: "输入参数")),
                .init(id: "legacy", title: "Legacy Web"),
                .init(id: "action", title: "Default Action", mode: .action, keywords: [])
            ],
            webEntry: "index.html"
        )
        let source = support.appendingPathComponent("Source")
        try writePlugin(manifest, to: source)
        let paths = AppPaths(applicationSupportDirectory: support, resourceDirectory: support)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: source), confirmed: true)
        return (support, pluginID)
    }

    private func writePlugin(_ manifest: PluginManifest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("leap.onInvoke(() => 'details');".utf8).write(to: directory.appendingPathComponent("main.js"))
        try Data("<html><body>Details</body></html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<12 {
            if element.exists, element.isHittable { return }
            scroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTFail("详情内容应能滚动查看：\(element)。")
    }

    @MainActor
    private func choosePluginDirectory(_ directory: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        // 鼠标先把焦点交给系统目录选择器，避免“前往文件夹”快捷键被后台应用接收。
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(directory.path)
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let navigated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [navigated], timeout: 5), .completed)
        choose.click()
    }
}
