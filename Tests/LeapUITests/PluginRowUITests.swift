import Foundation
import LeapCore
import XCTest

extension PluginDetailsUITests {
    @MainActor
    func testPluginRowMenuRespondsAcrossLayouts() throws {
        let fixture = try makeFixture(name: String(repeating: "长名称插件 ", count: 12))
        let app = launch(support: fixture.support)
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        let details = app.buttons["settings.pluginDetails.\(fixture.id)"]
        let menu = app.descendants(matching: .any)["settings.pluginMenu.\(fixture.id)"].firstMatch
        let back = app.buttons["settings.pluginDetails.back"]
        let officialMenu = app.descendants(matching: .any)["settings.pluginMenu.\(AppPaths.templateGeneratorID)"]
        XCTAssertFalse(officialMenu.firstMatch.exists)

        for layout in ["默认窗口", "最小窗口", "侧栏收起"] {
            if layout == "最小窗口" {
                let corner = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                    .withOffset(CGVector(dx: -2, dy: -2))
                corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -300)))
                XCTAssertEqual(settings.frame.width, 860, accuracy: 2)
            } else if layout == "侧栏收起" {
                settings.toolbars.buttons.firstMatch.click()
            }
            XCTAssertTrue(menu.isHittable)
            XCTAssertLessThanOrEqual(details.frame.maxX, menu.frame.minX)
            // 使用真实鼠标坐标检查按钮内缘，避免仅验证辅助功能的精准点击。
            for horizontalOffset in [menu.frame.width / 2, CGFloat(2), menu.frame.width - 2] {
                menu.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: horizontalOffset, dy: menu.frame.height / 2)).click()
                XCTAssertTrue(app.menuItems["从本地目录更新…"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.menuItems["卸载"].exists)
                XCTAssertFalse(back.exists, "管理菜单不应打开详情。")
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                XCTAssertTrue(app.menuItems["从本地目录更新…"].waitForNonExistence(timeout: 3))
            }
            // 箭头属于同一个详情按钮，其所在的右侧区域也应能进入详情。
            details.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -6, dy: 0)).click()
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.click()
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: settings.screenshot())
            screenshot.name = "插件行管理入口-\(layout)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        details.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 60, dy: 0)).click()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPluginRowMenuUpdatesAndUninstallsWithoutOpeningDetails() throws {
        let fixture = try makeFixture()
        let updated = fixture.support.appendingPathComponent("RowUpdateSource")
        try writePlugin(
            PluginManifest(
                id: fixture.id, name: "Updated Row Plugin", version: "2.0.0", runtime: .javascript,
                entry: "main.js", commands: [.init(id: "run", title: "Updated Row Command")]
            ),
            to: updated
        )
        let app = launch(support: fixture.support)
        let menu = app.descendants(matching: .any)["settings.pluginMenu.\(fixture.id)"].firstMatch
        let details = app.buttons["settings.pluginDetails.\(fixture.id)"]
        menu.click()
        app.menuItems["从本地目录更新…"].click()
        try choosePluginDirectory(updated, in: app)
        let install = app.sheets.buttons["安装 Updated Row Plugin"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()
        let refreshed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "查看 Updated Row Plugin 详情"), object: details
        )
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["settings.pluginDetails.back"].exists)
        menu.click()
        app.menuItems["卸载"].click()
        let confirm = app.sheets.buttons["卸载 Updated Row Plugin"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // 取消应保留插件，确认后仅删除受管副本。
        app.sheets.buttons["取消"].click()
        XCTAssertTrue(details.exists)
        menu.click()
        app.menuItems["卸载"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["settings.pluginDetails.back"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.appendingPathComponent("manifest.json").path))
    }
}
