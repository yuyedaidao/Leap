import AppKit
import Foundation
import LeapCore
import XCTest

final class PluginTemplateGeneratorUITests: XCTestCase {
    @MainActor
    func testGenerateTemplateChooseDirectoryAndOpenFinder() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapTemplateUI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Support"), resourceDirectory: root
        )
        let installer = PluginInstaller(paths: paths)
        // 隔离目录保持为空，验证应用随包插件无需预安装即可使用。

        let app = XCUIApplication()
        app.launchArguments += [
            "-leap-testing-support-directory", paths.applicationSupportDirectory.path
        ]
        addTeardownBlock {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            self.add(tree)
            app.terminate()
        }
        app.launch()
        app.activate()
        let search = app.textFields["launcher.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("template.generate")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let window = app.dialogs["com.padding.leap.launcher"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 800, accuracy: 2)
        XCTAssertTrue(app.buttons["plugin.backButton"].exists)
        XCTAssertFalse(app.windows["plugin.webWindow"].exists)

        try chooseDirectory(root, in: app)
        fillForm(in: app)
        app.buttons["添加命令"].click()
        let secondTitle = app.textFields.matching(identifier: "命令标题").element(boundBy: 1)
        XCTAssertTrue(secondTitle.waitForExistence(timeout: 5), app.debugDescription)
        secondTitle.click()
        secondTitle.typeText("UI Second")
        app.buttons["生成插件模板"].click()
        let generated = root.appendingPathComponent("ui-generated")
        // Finder 激活会结束内嵌会话；用落盘结果验证生成，而非查询已销毁网页的成功提示。
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: generated.appendingPathComponent("manifest.json").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        let manifest = try PluginManifestValidator().load(from: generated)
        XCTAssertEqual(manifest.id, "com.leap.plugin.ui-generated")
        XCTAssertEqual(manifest.commands.first?.id, "com.leap.plugin.ui-generated.run")
        XCTAssertEqual(manifest.commands.first?.title, "UI Generated")
        XCTAssertEqual(manifest.commands.count, 2)
        XCTAssertEqual(manifest.commands[1].id, "com.leap.plugin.ui-generated.run2")
        XCTAssertEqual(manifest.commands[1].title, "UI Second")
        XCTAssertEqual(manifest.runtime, .javascript)
        XCTAssertEqual(manifest.webEntry, "index.html")
        XCTAssertEqual(manifest.webWindow, .init(width: 800, height: 600))
        XCTAssertEqual(manifest.commands.first?.mode, .interactive)
        XCTAssertEqual(manifest.commands.first?.presentation, .web)
        // Finder 属于外部应用，读取前台归属验证已打开，避免其辅助功能快照阻塞测试。
        let openedFinder = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [openedFinder], timeout: 5), .completed)

        // 用真实安装器安装生成结果，再重新启动隔离宿主执行网页按钮。
        try installer.install(try installer.inspect(sourceDirectory: generated), confirmed: true)
        runGeneratedPlugin(in: app)
    }

    @MainActor
    func testBuiltInGeneratorMultipleCommandControls() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapOfficialControls-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", support.path,
                                "-leap-testing-open-plugin", AppPaths.templateGeneratorID]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        let add = app.buttons["添加命令"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.click()
        XCTAssertEqual(app.textFields.matching(identifier: "命令标题").count, 2)
        let remove = app.buttons.matching(identifier: "删除命令")
        XCTAssertEqual(remove.count, 2)
        XCTAssertTrue(remove.element(boundBy: 1).isEnabled)
        remove.element(boundBy: 1).click()
        XCTAssertEqual(app.textFields.matching(identifier: "命令标题").count, 1)
        XCTAssertFalse(app.buttons["删除命令"].isEnabled)
        XCTAssertTrue(app.buttons["生成插件模板"].exists)
    }

    @MainActor
    func testOfficialPluginSettingsCannotUpdateOrUninstall() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapOfficialUI-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments += ["-leap-testing-support-directory", support.path]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launch()
        // 使用实际设置入口，插件来源验证无需依赖应用菜单的激活状态。
        app.buttons["launcher.settingsButton"].click()
        let settings = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        let plugins = app.descendants(matching: .any)["settings.section.plugins"].firstMatch
        XCTAssertTrue(plugins.waitForExistence(timeout: 5))
        plugins.click()
        XCTAssertTrue(app.staticTexts["内置"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["settings.pluginDetails.\(AppPaths.templateGeneratorID)"].exists)
        XCTAssertFalse(app.buttons["更新"].exists)
        XCTAssertFalse(app.buttons["卸载"].exists)
        XCTAssertTrue(app.buttons["settings.installPluginButton"].exists)
    }

    @MainActor
    private func chooseDirectory(_ root: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["选择目录…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        // 启动器是非激活面板，操作系统对话框前显式激活，避免 XCTest 将其当作中断窗口。
        app.activate()
        choose.click()
        let cancel = app.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(choose.isEnabled)
        XCTAssertEqual(app.textFields["目录"].value as? String ?? "", "")
        choose.click()
        let confirmDirectory = app.buttons["OKButton"]
        XCTAssertTrue(confirmDirectory.waitForExistence(timeout: 5), app.debugDescription)
        let newFolder = app.buttons["NewFolderButton"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(newFolder.isEnabled, "目录选择器应允许新建文件夹。")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let location = app.textFields["PathTextField"]
        XCTAssertTrue(location.waitForExistence(timeout: 5), app.debugDescription)
        // “前往文件夹”自动聚焦并全选路径，直接替换可避免额外选择触发第三方取词浮层。
        location.typeText(root.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let navigated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: location)
        XCTAssertEqual(XCTWaiter.wait(for: [navigated], timeout: 5), .completed, app.debugDescription)
        newFolder.click()
        // 系统新建文件夹面板自动聚焦名称输入，Return 确认创建并选中目录。
        app.typeText("ui-generated")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let created = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-generated").path)
        }
        expectation(for: created, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        confirmDirectory.click()
    }

    @MainActor
    private func fillForm(in app: XCUIApplication) {
        let field = app.textFields["插件名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        field.typeText("UI Generated")
        // 高级设置保持折叠且不填写，验证实际生成使用占位提示的默认值。
        XCTAssertFalse(app.textFields["插件 ID"].isHittable)
    }

    @MainActor
    private func runGeneratedPlugin(in app: XCUIApplication) {
        app.terminate()
        app.launchArguments += ["-leap-testing-open-plugin", "com.leap.plugin.ui-generated"]
        app.launch()
        let run = app.buttons["运行"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.click()
        XCTAssertTrue(app.staticTexts["hello"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
