import Foundation
import LeapCore
import XCTest

final class PluginWebWindowUITests: XCTestCase {
    @MainActor
    func testDefaultResizeFocusAndReopen() throws {
        let app = try launchPlugin(size: .init(width: 800, height: 600))
        let window = app.windows["plugin.webWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(window.frame.width, 800, accuracy: 2)
        XCTAssertGreaterThan(window.frame.height, 600)
        XCTAssertLessThan(window.frame.height, 650)
        let initialWindow = window.frame
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        let initialWeb = web.frame
        XCTAssertEqual(initialWeb.width, 800, accuracy: 2)
        XCTAssertEqual(initialWeb.height, 600, accuracy: 2)
        XCTAssertFalse(app.buttons["plugin.closeButton"].exists)
        resize(window, by: CGVector(dx: 100, dy: 80))
        let resized = NSPredicate { _, _ in window.frame.width > initialWindow.width + 50 }
        _ = expectation(for: resized, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(web.frame.width, window.frame.width, accuracy: 2)
        XCTAssertEqual(web.frame.height - initialWeb.height, window.frame.height - initialWindow.height, accuracy: 2)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(window.exists, "切换应用不能隐藏插件窗口。")
        app.activate()
        window.click()
        app.buttons["调用 Leap"].click()
        XCTAssertTrue(app.staticTexts["Web: web.echo / 来自网页"].waitForExistence(timeout: 5))
        window.buttons[XCUIIdentifierCloseWindow].click()
        reopenPlugin(in: app)
        XCTAssertEqual(window.frame.width, 800, accuracy: 2)
        XCTAssertEqual(window.frame.height, initialWindow.height, accuracy: 2)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        reopenPlugin(in: app)
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.exists)
        XCTAssertTrue(app.staticTexts["最近使用"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "launcher.command.com.padding.leap.web-echo/web.echo").count, 1)
    }

    @MainActor
    func testGlobalHotKeyPreservesPluginWindow() throws {
        let app = try launchPlugin(size: .init(width: 800, height: 600))
        let window = app.windows["plugin.webWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.click()
        app.typeKey("l", modifierFlags: [.option, .command])
        // 单独验证快捷键，避免已有快捷键失败阻止尺寸及关闭行为的回归验证。
        let launcherAppeared = app.dialogs["com.padding.leap.launcher"].waitForExistence(timeout: 5)
        XCTAssertTrue(window.exists, "唤起启动器不能关闭插件窗口。")
        XCTAssertTrue(launcherAppeared, "全局快捷键应唤起启动器。")
    }

    @MainActor
    func testLegacySizeAndMinimumResize() throws {
        let app = try launchPlugin(size: nil)
        let window = app.windows["plugin.webWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 560, accuracy: 2)
        XCTAssertGreaterThan(window.frame.height, 360)
        resize(window, by: CGVector(dx: -300, dy: -300))
        XCTAssertGreaterThanOrEqual(window.frame.width, 400)
        XCTAssertGreaterThanOrEqual(window.frame.height, 300)
    }

    @MainActor
    func testOversizedDefaultFitsScreen() throws {
        let app = try launchPlugin(size: .init(width: 100_000, height: 100_000))
        let window = app.windows["plugin.webWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // 超大清单应被屏幕范围限制，而不是创建无法操作的巨大窗口。
        XCTAssertLessThan(window.frame.width, 100_000)
        XCTAssertLessThan(window.frame.height, 100_000)
        XCTAssertTrue(window.buttons[XCUIIdentifierCloseWindow].isHittable)
    }

    @MainActor
    private func launchPlugin(size: PluginManifest.WebWindow?) throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapWindowUI-\(UUID().uuidString)")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: project.appendingPathComponent("Examples/Plugins/WebEcho"), to: source)
        let old = try PluginManifestValidator().load(from: source)
        let manifest = PluginManifest(
            id: old.id, name: old.name, version: old.version, runtime: old.runtime,
            entry: old.entry, commands: old.commands, webEntry: old.webEntry, webWindow: size
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let installer = PluginInstaller(paths: AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Support"), resourceDirectory: root
        ))
        try installer.install(try installer.inspect(sourceDirectory: source), confirmed: true)
        let app = XCUIApplication()
        app.launchArguments += [
            "-leap-testing-support-directory", root.appendingPathComponent("Support").path,
            "-leap-testing-open-plugin", old.id
        ]
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

    @MainActor
    private func reopenPlugin(in app: XCUIApplication) {
        // 关闭后应直接从最近使用重新打开，不能依赖搜索结果掩盖漏记历史的问题。
        XCTAssertTrue(app.staticTexts["最近使用"].waitForExistence(timeout: 5))
        let command = app.buttons["launcher.command.com.padding.leap.web-echo/web.echo"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), app.windows.debugDescription)
        // 焦点恢复会重建最近项目的 AX 元素，从稳定的窗口坐标点击，避免复用已失效的元素句柄。
        let launcher = app.dialogs["com.padding.leap.launcher"]
        let frame = app.buttons.matching(identifier: "launcher.command.com.padding.leap.web-echo/web.echo")
            .firstMatch.frame
        let origin = launcher.frame.origin
        launcher.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).click()
        XCTAssertTrue(app.windows["plugin.webWindow"].waitForExistence(timeout: 5))
        app.windows["plugin.webWindow"].click()
    }

    @MainActor
    private func resize(_ window: XCUIElement, by offset: CGVector) {
        window.click()
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(offset))
    }
}
