import AppKit
import CoreGraphics
import LeapCore
import XCTest

final class SettingsWindowUITests: XCTestCase {
    @MainActor
    func testAppUpdateSettingsAreAvailableWithoutNetwork() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let toggle = app.descendants(matching: .any)["settings.autoUpdateToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        let original = String(describing: toggle.value)
        toggle.click()
        XCTAssertNotEqual(String(describing: toggle.value), original)
        app.descendants(matching: .any)["settings.section.about"].firstMatch.click()
        let check = app.buttons["settings.checkForUpdatesButton"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertFalse(check.isEnabled, "隔离 UI 测试不启动真实更新器。")
    }

    @MainActor
    func testDetailPagesUseSystemNavigationTitles() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let sections = [("general", "通用"), ("plugins", "插件"), ("data", "数据与隐私"), ("about", "关于")]
        for (section, title) in sections {
            settings.descendants(matching: .any)["settings.section.\(section)"].firstMatch.click()
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "title == %@", title), object: settings
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        let appIcon = settings.images["settings.about.appIcon"]
        XCTAssertTrue(appIcon.waitForExistence(timeout: 5))
        XCTAssertEqual(appIcon.label, "Leap 应用图标")
        XCTAssertEqual(appIcon.frame.width, 48, accuracy: 1)
        XCTAssertEqual(appIcon.frame.height, 48, accuracy: 1)
        attachScreenshot(settings, name: "关于页应用图标与系统导航标题")
    }

    @MainActor
    func testWindowControlsSidebarToggleAndDragging() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let sidebar = settings.outlines.firstMatch
        XCTAssertTrue(sidebar.exists)
        let close = settings.buttons[XCUIIdentifierCloseWindow]
        let minimize = settings.buttons[XCUIIdentifierMinimizeWindow]
        let toggle = settings.toolbars.buttons.firstMatch
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(minimize.isHittable)
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(settings.title, "通用")
        XCTAssertLessThan(close.frame.maxX, sidebar.frame.maxX)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, sidebar.frame.maxX + 8)
        let general = app.descendants(matching: .any)["settings.section.general"].firstMatch
        XCTAssertGreaterThan(general.frame.minY, max(close.frame.maxY, toggle.frame.maxY))
        attachScreenshot(settings, name: "窗口控制区与侧栏融合")

        app.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"].click()
        let back = app.buttons["settings.pluginDetails.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        toggle.click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: general)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(minimize.isHittable)
        XCTAssertTrue(back.isHittable)
        attachScreenshot(settings, name: "侧栏收起后保留插件详情")
        toggle.click()
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertTrue(general.isHittable)
        XCTAssertTrue(back.isHittable)

        let original = settings.frame
        // 控制区空白部分仍是原生可拖动标题栏，不触发列表或窗口按钮。
        let start = settings.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: (minimize.frame.maxX + toggle.frame.minX) / 2 - original.minX,
            dy: close.frame.midY - original.minY
        ))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 30)))
        XCTAssertGreaterThan(settings.frame.minX, original.minX + 20)
        XCTAssertEqual(settings.frame.size, original.size)
    }

    @MainActor
    func testSidebarNavigationKeyboardAndResize() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let original = settings.frame
        XCTAssertEqual(original.width, 900, accuracy: 2)
        XCTAssertGreaterThanOrEqual(original.height, 560)
        XCTAssertTrue(app.descendants(matching: .any)["settings.launchAtLoginToggle"].firstMatch.exists)

        app.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings.section.data"].firstMatch.click()
        XCTAssertTrue(app.buttons["settings.clearRecentButton"].waitForExistence(timeout: 5))
        let about = app.descendants(matching: .any)["settings.section.about"].firstMatch
        about.click()
        XCTAssertTrue(app.staticTexts["Leap"].exists)
        // 列表保留原生键盘导航，上一项应进入“数据与隐私”。
        about.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["settings.clearRecentButton"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings.section.general"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.launchAtLoginToggle"].firstMatch.exists)

        resize(settings, by: CGVector(dx: -300, dy: -300))
        XCTAssertEqual(settings.frame.width, 860, accuracy: 2)
        // 原生工具栏会改变标题栏高度，检验下限时不使用默认窗口的标题栏差值。
        XCTAssertGreaterThanOrEqual(settings.frame.height, 500)
        let minimum = settings.frame
        resize(settings, by: CGVector(dx: -100, dy: -100))
        XCTAssertEqual(settings.frame.width, minimum.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, minimum.height, accuracy: 2)
        app.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        XCTAssertTrue(app.buttons["settings.installPluginButton"].isHittable)
        attachScreenshot(settings, name: "设置最小尺寸")
        resize(settings, by: CGVector(dx: 100, dy: 80))
        XCTAssertGreaterThan(settings.frame.width, original.width)
        let resized = settings.frame
        settings.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(settings.frame, resized)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        attachScreenshot(settings, name: "设置侧栏与插件列表")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(settings.frame.width, resized.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, resized.height, accuracy: 2)
        XCTAssertTrue(app.buttons["settings.installPluginButton"].isHittable)
    }

    @MainActor
    func testSettingsMenuAndShortcutUseTheSameWindow() {
        let app = launchForSettingsTest()
        app.activate()
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(settings.buttons[XCUIIdentifierCloseWindow].isHittable)
        app.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        let original = settings.frame
        settings.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        XCTAssertEqual(settings.frame, original)
        XCTAssertTrue(settings.buttons[XCUIIdentifierCloseWindow].isHittable)
        XCTAssertTrue(app.buttons["settings.installPluginButton"].exists, "再次打开应保留选中的设置页。")
        // 直接用键盘关闭，确认焦点交接后快捷键实际作用于设置窗口。
        settings.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    }

    @MainActor
    func testSettingsRestoresFromMinimization() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let original = settings.frame
        settings.buttons[XCUIIdentifierMinimizeWindow].click()
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: settings.buttons[XCUIIdentifierCloseWindow]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        XCTAssertEqual(settings.frame.width, original.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, original.height, accuracy: 2)
    }

    @MainActor
    func testSettingsReturnsToNormalLevelAndCanBePresentedAgain() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let original = settings.frame
        XCTAssertEqual(settingsWindowLayer(frame: original), Int(CGWindowLevelForKey(.floatingWindow)))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let normalLevel = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.settingsWindowLayer(frame: original) == Int(CGWindowLevelForKey(.normalWindow))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [normalLevel], timeout: 5), .completed)

        // 使用设置入口重开，避免测试依赖用户自定义的全局启动器快捷键。
        app.menuBars.menuBarItems["Leap"].click()
        app.menuItems["设置…"].click()
        let foreground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: settings.buttons[XCUIIdentifierCloseWindow]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 5), .completed)
        XCTAssertEqual(settingsWindowLayer(frame: settings.frame), Int(CGWindowLevelForKey(.floatingWindow)))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings.window").count, 1)
        XCTAssertEqual(settings.frame.width, original.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, original.height, accuracy: 2)
    }

    @MainActor
    private func launchForSettingsTest() -> XCUIApplication {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("LeapSettingsUI-\(UUID())")
        let app = XCUIApplication()
        // 使用参数域覆盖测试快捷键，避免修改用户偏好或依赖用户自定义的按键组合。
        app.launchArguments += [
            "-leap-testing-support-directory", support.path,
            "-globalHotKeyShortcut", "testing-default",
            "-automaticallyChecksForUpdatesOnLaunch", "YES"
        ]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        XCTAssertTrue(app.buttons["launcher.settingsButton"].waitForExistence(timeout: 5))
        return app
    }

    private func settingsWindowLayer(frame: CGRect) -> Int? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let info = windows.first { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.padding.leap",
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return abs(width - frame.width) < 2 && abs(height - frame.height) < 2
        }
        return info?[kCGWindowLayer as String] as? Int
    }

    @MainActor
    private func resize(_ window: XCUIElement, by offset: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(offset))
    }

    @MainActor
    private func attachScreenshot(_ window: XCUIElement, name: String) {
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

extension SettingsWindowUITests {
    @MainActor
    func testPluginPickerStaysCenteredWhenWindowWidens() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        let source = settings.toolbars.descendants(matching: .any)["settings.pluginSource"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        for delta in [0, 200, 300] {
            if delta > 0 { resize(settings, by: CGVector(dx: delta, dy: 0)) }
            let sidebar = settings.outlines.firstMatch
            let center = (sidebar.frame.maxX + settings.frame.maxX) / 2
            attachScreenshot(settings, name: "插件筛选居中 \(Int(settings.frame.width))")
            XCTAssertEqual(source.frame.midX, center, accuracy: 3, "窗口变宽后筛选仍应位于内容区域中心。")
        }
    }

    @MainActor
    func testRemotePluginInstallerCanValidateAddressAndCancel() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        app.toolbars.buttons["settings.installPluginButton"].click()
        let remote = app.buttons["从远程地址安装"]
        XCTAssertTrue(remote.waitForExistence(timeout: 5))
        remote.click()
        let field = app.textFields["settings.remotePluginAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.remotePluginDownload"].isEnabled)
        field.click()
        field.typeText("https://github.com/owner/repo")
        app.buttons["settings.remotePluginDownload"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.remotePluginError"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["settings.remotePluginCancel"].click()
        XCTAssertFalse(field.exists)
        XCTAssertTrue(app.toolbars.buttons["settings.installPluginButton"].isHittable)
    }

    @MainActor
    func testPluginToolbarUsesCenteredPickerAndNativeSearch() {
        let app = launchForSettingsTest()
        app.buttons["launcher.settingsButton"].click()
        app.activate()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any)["settings.section.plugins"].firstMatch.click()
        let source = settings.toolbars.descendants(matching: .any)["settings.pluginSource"].firstMatch
        let search = settings.toolbars.searchFields.firstMatch
        let install = settings.toolbars.buttons["settings.installPluginButton"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.isHittable)
        // 系统分段控件的辅助功能边界不包含工具栏玻璃背景的内边距。
        XCTAssertGreaterThanOrEqual(source.frame.width, 180)
        XCTAssertLessThanOrEqual(source.frame.width, 220)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(install.isHittable)
        XCTAssertEqual(install.label, "安装插件")
        XCTAssertLessThanOrEqual(source.frame.maxX, install.frame.minX)
        XCTAssertLessThanOrEqual(install.frame.maxX, search.frame.minX)
        attachScreenshot(settings, name: "插件中央筛选与系统搜索")
        resize(settings, by: CGVector(dx: -300, dy: -300))
        XCTAssertEqual(settings.frame.width, 860, accuracy: 2)
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(install.isHittable)
        XCTAssertLessThanOrEqual(search.frame.maxX, settings.frame.maxX)
        XCTAssertLessThanOrEqual(source.frame.maxX, install.frame.minX)
        attachScreenshot(settings, name: "最小窗口插件工具栏系统搜索")
        let toggle = settings.toolbars.buttons.firstMatch
        toggle.click()
        let general = settings.descendants(matching: .any)["settings.section.general"].firstMatch
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: general)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(install.isHittable)
        attachScreenshot(settings, name: "最小窗口侧栏收起后的插件工具栏")
        toggle.click()
        for section in ["general", "data", "about"] {
            settings.descendants(matching: .any)["settings.section.\(section)"].firstMatch.click()
            XCTAssertFalse(source.exists)
            XCTAssertFalse(search.exists)
            XCTAssertFalse(install.exists)
        }
    }
}
