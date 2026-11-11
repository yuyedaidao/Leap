import Foundation
import XCTest

final class PluginStoreUITests: XCTestCase {
    @MainActor
    func testStoreBrowsesCachedIndexAndSearches() {
        let app = launchForStoreTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()

        let storeButton = app.toolbars.buttons["settings.pluginStoreButton"]
        XCTAssertTrue(storeButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(storeButton.isHittable)
        XCTAssertEqual(storeButton.label, "插件商店")
        storeButton.click()

        let list = settings.descendants(matching: .any)["settings.pluginStoreList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        let titled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title == %@", "插件商店"), object: settings
        )
        XCTAssertEqual(XCTWaiter.wait(for: [titled], timeout: 5), .completed)

        XCTAssertTrue(installRow(settings, "alpha").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(installRow(settings, "beta").exists)
        let group = settings.descendants(matching: .any)["settings.pluginStoreGroup"].firstMatch
        XCTAssertTrue(group.label.contains("2"))

        let search = settings.toolbars.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("关机")
        // 列表过滤会移除行，逐次重新查询避免复用已失效的元素。
        XCTAssertTrue(installRow(settings, "beta").waitForExistence(timeout: 5))
        XCTAssertFalse(installRow(settings, "alpha").exists, "搜索应过滤掉不匹配的插件。")
        XCTAssertEqual(
            settings.buttons.matching(identifier: "settings.pluginStoreInstall.com.example.leap.beta").count, 1)

        attachScreenshot(settings, name: "插件商店列表")
        app.toolbars.buttons["settings.pluginDetails.back"].click()
        XCTAssertTrue(app.toolbars.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStoreButtonSitsBetweenInstallButtonAndSearch() {
        let app = launchForStoreTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()

        let install = app.toolbars.buttons["settings.installPluginButton"]
        let store = app.toolbars.buttons["settings.pluginStoreButton"]
        let search = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        XCTAssertTrue(store.exists)
        XCTAssertTrue(search.exists)
        XCTAssertLessThanOrEqual(install.frame.maxX, store.frame.minX)
        XCTAssertLessThanOrEqual(store.frame.maxX, search.frame.minX)
    }

    @MainActor
    private func launchForStoreTest() -> XCUIApplication {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapStoreUI-\(UUID())")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // 离线夹具：索引只来自缓存，用例不访问真实网络。
        let indexURL = support.appendingPathComponent("PluginStore/store.json")
        try? FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(
            """
            {"schemaVersion": 1, "name": "官方插件", "plugins": [
              {"id": "com.example.leap.alpha", "name": "示例甲", "version": "1.0.0",
               "summary": "演示插件", "path": "plugins/alpha", "runtime": "javascript", "commands": ["示例甲"]},
              {"id": "com.example.leap.beta", "name": "示例乙", "version": "2.0.0",
               "summary": "关机助手", "path": "plugins/beta", "runtime": "javascript", "commands": ["示例乙"]}
            ]}
            """.utf8
        ).write(to: indexURL)

        let app = XCUIApplication()
        app.launchArguments += [
            "-leap-testing-support-directory", support.path,
            "-leap-testing-offline-store",
            "-globalHotKeyShortcut", "testing-default",
            "-automaticallyChecksForUpdatesOnLaunch", "NO"
        ]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        XCTAssertTrue(app.buttons["launcher.settingsButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func installRow(_ settings: XCUIElement, _ name: String) -> XCUIElement {
        settings.buttons["settings.pluginStoreInstall.com.example.leap.\(name)"]
    }

    @MainActor
    private func attachScreenshot(_ window: XCUIElement, name: String) {
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
