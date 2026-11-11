import Foundation
import LeapCore
import XCTest

final class PluginDetailsUITests: XCTestCase {
    private let longKeyword = String(repeating: "long-keyword-", count: 16)
    private let longPattern = "^" + String(repeating: "(leap-[a-z0-9]+)", count: 16) + "$"

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
        let originalTitle = settings.title
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.frame, original)
        XCTAssertEqual(settings.title, originalTitle)
        XCTAssertFalse(settings.title.isEmpty)
        XCTAssertNotEqual(settings.title, "插件")
        let back = settings.toolbars.buttons["settings.pluginDetails.back"]
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        app.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.title, "插件")
    }

    @MainActor
    func testLongPluginTitleFitsMinimumWindowSize() throws {
        let name = String(repeating: "长名称插件 ", count: 12)
        let fixture = try makeFixture(name: name)
        let app = launch(support: fixture.support)
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let corner = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -300)))
        XCTAssertEqual(settings.frame.width, 860, accuracy: 2)
        XCTAssertEqual(settings.title, name)
        XCTAssertTrue(settings.buttons[XCUIIdentifierCloseWindow].isHittable)
        let back = settings.toolbars.buttons["settings.pluginDetails.back"]
        XCTAssertTrue(back.isHittable)
        settings.toolbars.buttons.firstMatch.click()
        XCTAssertEqual(settings.title, name)
        XCTAssertTrue(back.isHittable)
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "最小窗口与长插件标题"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testDetailsShowKeywordsRulesAndLegacyModes() throws {
        let fixture = try makeFixture()
        let app = launch(support: fixture.support)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let originalFrame = settings.frame
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        let list = app.descendants(matching: .any)["settings.pluginDetails.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(list.elementType == .outline || list.outlines.firstMatch.exists)
        XCTAssertEqual(settings.frame, originalFrame)
        XCTAssertEqual(settings.title, "Details Plugin")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)

        let keywords = app.staticTexts["settings.pluginCommand.first.keywords"]
        scrollTo(keywords, in: list)
        XCTAssertEqual(keywords.value as? String, "alpha、shared、\(longKeyword)")
        XCTAssertGreaterThan(keywords.frame.height, 20, "长关键字应换行，不能截断。")
        XCTAssertTrue(app.staticTexts["动作 · 后台执行"].exists)
        let defaultLimits = "\(1.formatted())–\(1000.formatted())"
        scrollTo(app.staticTexts["文本匹配 · \(defaultLimits) 个字符"], in: list)
        scrollTo(app.staticTexts["^leap-[0-9]+$"], in: list)
        XCTAssertTrue(app.staticTexts["正则匹配 · 3–32 个字符"].exists)

        let secondKeywords = app.staticTexts["settings.pluginCommand.second.keywords"]
        scrollTo(secondKeywords, in: list)
        XCTAssertEqual(secondKeywords.value as? String, "beta、shared", "不同命令的关键字应分别展示。")
        XCTAssertTrue(app.staticTexts["内嵌列表交互"].exists)
        scrollTo(app.staticTexts["输入参数"], in: list)
        let legacy = app.staticTexts["settings.pluginCommand.legacy.behavior"]
        scrollTo(legacy, in: list)
        XCTAssertEqual(legacy.value as? String, "独立网页窗口")
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.legacy.keywords"].value as? String, "未声明额外关键字")
        let action = app.staticTexts["settings.pluginCommand.action.behavior"]
        scrollTo(action, in: list)
        XCTAssertEqual(action.value as? String, "动作 · 等待完成")
        XCTAssertTrue(app.staticTexts["未声明内容匹配规则"].exists)

        let technical = app.descendants(matching: .any)["settings.pluginDetails.technical"].firstMatch
        scrollTo(technical, in: list)
        XCTAssertFalse(app.descendants(matching: .any)["settings.pluginDetails.id"].firstMatch.exists)
        list.disclosureTriangles.firstMatch.click()
        scrollTo(app.descendants(matching: .any)["settings.pluginDetails.id"].firstMatch, in: list)
        scrollTo(app.staticTexts["main.js"], in: list)
        XCTAssertTrue(app.staticTexts["javascript"].exists)
        scrollTo(app.staticTexts["未声明"], in: list)
        scrollTo(technical, in: list, deltaY: 220)
        list.disclosureTriangles.firstMatch.click()
        XCTAssertFalse(app.descendants(matching: .any)["settings.pluginDetails.id"].firstMatch.exists)
        app.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.\(fixture.id)"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.frame, originalFrame)
    }

    @MainActor
    func testOfficialPluginDetailsKeepManagementRestrictions() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDetailsUI-\(UUID())")
        let app = launch(support: support)
        app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["内置"].exists)
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
            id: fixture.id, name: "Updated Details Plugin", version: "2.0.0", runtime: .javascript, entry: "main.js",
            commands: [.init(id: "first", title: "Updated Command", keywords: ["updated-keyword"])]
        )
        try writePlugin(manifest, to: updated)
        let app = launch(support: fixture.support)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].waitForExistence(timeout: 5))
        app.activate()
        app.buttons["更新"].click()
        let local = app.sheets.buttons["从本地目录更新"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sheets.buttons["从远程地址更新"].exists)
        local.click()
        try choosePluginDirectory(updated, in: app)
        // SwiftUI 同时暴露不可见的确认动作，定位实际系统 sheet 中的按钮。
        let install = app.sheets.buttons["更新 Updated Details Plugin"]
        XCTAssertTrue(install.waitForExistence(timeout: 5), app.debugDescription)
        install.click()
        let version = app.staticTexts["settings.pluginDetails.version"]
        let refreshed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS '2.0.0'"), object: version
        )
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        XCTAssertEqual(settings.title, "Updated Details Plugin")
        XCTAssertTrue(app.buttons["settings.pluginDetails.back"].exists)
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.first.keywords"].value as? String, "updated-keyword")
        XCTAssertTrue(app.staticTexts["Updated Command"].exists)
        XCTAssertEqual(app.staticTexts["settings.pluginCommand.first.behavior"].value as? String, "动作 · 等待完成")

        app.buttons["卸载"].click()
        let confirm = app.sheets.buttons["卸载 Updated Details Plugin"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.pluginDetails.back"].exists)
        XCTAssertEqual(settings.title, "插件")
        XCTAssertFalse(app.buttons["settings.pluginDetails.\(fixture.id)"].exists)
        // 卸载仅清理受管副本，测试的更新源目录必须仍在。
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    func launch(support: URL) -> XCUIApplication {
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

    func makeFixture(
        name: String = "Details Plugin", extraCommandCount: Int = 0, source remote: RemotePluginSource? = nil
    ) throws -> (support: URL, id: String) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapDetailsUI-\(UUID())")
        let pluginID = "com.padding.leap.details-\(UUID().uuidString.lowercased())"
        let manifest = PluginManifest(
            id: pluginID, name: name, version: "1.0.0", runtime: .javascript, entry: "main.js",
            commands: [
                .init(id: "first", title: "First Command", executionMode: .background, mode: .action,
                      keywords: ["alpha", "shared", longKeyword],
                      matches: [.init(type: .text), .init(type: .regex, pattern: "^leap-[0-9]+$",
                                                        minLength: 3, maxLength: 32),
                                .init(type: .regex, pattern: longPattern)]),
                .init(id: "second", title: "Second Command", mode: .interactive, presentation: .list,
                      keywords: ["beta", "shared"], input: .init(placeholder: "输入参数")),
                .init(id: "legacy", title: "Legacy Web"),
                .init(id: "action", title: "Default Action", mode: .action, keywords: [])
            ] + (0..<extraCommandCount).map { index in
                PluginManifest.Command(id: "extra-\(index)", title: "额外命令 \(index)", keywords: ["extra"])
            },
            webEntry: "index.html"
        )
        let source = support.appendingPathComponent("Source")
        try writePlugin(manifest, to: source)
        let paths = AppPaths(applicationSupportDirectory: support, resourceDirectory: support)
        let installer = PluginInstaller(paths: paths)
        try installer.install(try installer.inspect(sourceDirectory: source, source: remote), confirmed: true)
        return (support, pluginID)
    }

    func writePlugin(_ manifest: PluginManifest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("leap.onInvoke(() => 'details');".utf8).write(to: directory.appendingPathComponent("main.js"))
        try Data("<html><body>Details</body></html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in list: XCUIElement, deltaY: CGFloat = -220) {
        for _ in 0..<60 {
            if element.exists, element.isHittable { return }
            list.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTFail("详情内容应能滚动查看：\(element)。")
    }

    @MainActor
    func choosePluginDirectory(_ directory: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        // 鼠标先把焦点交给系统目录选择器，避免“前往文件夹”快捷键被后台应用接收。
        let search = app.sheets.searchFields.firstMatch
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

extension PluginDetailsUITests {
    @MainActor
    func testToolbarAddButtonInstallsLocalPlugin() throws {
        let fixture = try makeFixture()
        let directory = fixture.support.appendingPathComponent("ToolbarSource")
        let pluginID = fixture.id + ".new"
        try writePlugin(
            PluginManifest(
                id: pluginID, name: "Toolbar Installed Plugin", version: "1.0.0", runtime: .javascript,
                entry: "main.js", commands: [.init(id: "run", title: "Toolbar Command")]
            ),
            to: directory
        )
        let app = launch(support: fixture.support)
        let install = app.toolbars.buttons["settings.installPluginButton"]
        install.click()
        app.sheets.buttons["settings.installLocalPlugin"].click()
        try choosePluginDirectory(directory, in: app)
        let confirm = app.sheets.buttons["安装 Toolbar Installed Plugin"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(app.buttons["settings.pluginDetails.\(pluginID)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.toolbars.searchFields.firstMatch.isHittable)
        XCTAssertTrue(install.isHittable)
    }

    @MainActor
    func testLongValuesWrapAtMinimumWindowSize() throws {
        let fixture = try makeFixture()
        let app = launch(support: fixture.support)
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let corner = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -300)))
        let list = app.descendants(matching: .any)["settings.pluginDetails.list"].firstMatch
        let pattern = app.staticTexts.matching(NSPredicate(format: "value == %@", longPattern)).firstMatch
        scrollTo(pattern, in: list)
        XCTAssertGreaterThan(pattern.frame.height, 20, "长正则应换行展示。")
        let technical = app.descendants(matching: .any)["settings.pluginDetails.technical"].firstMatch
        scrollTo(technical, in: list)
        list.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.pluginDetails.id"].firstMatch.waitForExistence(timeout: 2),
            list.debugDescription
        )
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "原生列表最小窗口长文本"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testManyCommandsUseNativeRowsAndScrollToTechnicalInformation() throws {
        let fixture = try makeFixture(extraCommandCount: 30)
        let app = launch(support: fixture.support)
        app.buttons["settings.pluginDetails.\(fixture.id)"].click()
        let list = app.descendants(matching: .any)["settings.pluginDetails.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(list.elementType == .outline || list.outlines.firstMatch.exists)
        scrollTo(app.staticTexts["settings.pluginCommand.extra-29.keywords"], in: list)
        let technical = app.descendants(matching: .any)["settings.pluginDetails.technical"].firstMatch
        scrollTo(technical, in: list)
        let pluginID = app.descendants(matching: .any)["settings.pluginDetails.id"].firstMatch
        XCTAssertFalse(pluginID.exists)
        list.disclosureTriangles.firstMatch.click()
        scrollTo(pluginID, in: list)
        XCTAssertEqual(pluginID.value as? String, fixture.id)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "原生列表多命令与技术信息"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLibraryGroupsSearchAndManagementMenu() throws {
        let fixture = try makeFixture()
        let app = launch(support: fixture.support)
        let local = app.buttons["settings.pluginDetails.\(fixture.id)"]
        let official = app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"]
        XCTAssertTrue(local.exists)
        XCTAssertTrue(official.exists)
        let localGroup = app.staticTexts["settings.pluginGroup.local"]
        let officialGroup = app.staticTexts["settings.pluginGroup.official"]
        XCTAssertLessThan(localGroup.frame.minY, officialGroup.frame.minY)
        XCTAssertFalse(app.buttons["settings.pluginMenu.\(AppPaths.templateGeneratorID)"].exists)
        app.descendants(matching: .any)["settings.pluginMenu.\(fixture.id)"].firstMatch.click()
        XCTAssertTrue(app.menuItems["更新…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["卸载"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["settings.pluginDetails.back"].exists)

        let source = app.toolbars.descendants(matching: .any)["settings.pluginSource"].firstMatch
        source.descendants(matching: .any)["内置"].firstMatch.click()
        XCTAssertTrue(official.exists)
        XCTAssertFalse(local.exists)
        source.descendants(matching: .any)["自定义"].firstMatch.click()
        XCTAssertTrue(local.exists)
        XCTAssertFalse(official.exists)
        let search = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("ALPHA")
        XCTAssertTrue(local.exists)
        XCTAssertFalse(official.exists)
        XCTAssertTrue(local.label.contains("匹配命令：First Command"))
        local.click()
        XCTAssertFalse(search.exists)
        XCTAssertFalse(app.buttons["settings.installPluginButton"].exists)
        app.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "ALPHA")
        XCTAssertFalse(official.exists)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-matching-plugin")
        XCTAssertTrue(app.descendants(matching: .any)["settings.pluginEmptyState"].firstMatch.exists)
        // 原生搜索激活后，系统可能将安装入口移入工具栏溢出菜单。
        if !app.toolbars.buttons["settings.installPluginButton"].exists {
            let overflow = app.toolbars.popUpButtons.firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.click()
            XCTAssertTrue(app.menuItems["安装插件"].waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(local.exists)
        source.descendants(matching: .any)["全部"].firstMatch.click()
        XCTAssertTrue(official.exists)
    }
}
