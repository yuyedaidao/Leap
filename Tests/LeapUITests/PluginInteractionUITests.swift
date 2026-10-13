import AppKit
import Foundation
import LeapCore
import XCTest

final class PluginInteractionUITests: XCTestCase {
    @MainActor
    func testNumericShortcutsTitleSubtitlesAndExplicitLoading() throws {
        let script = """
        leap.onInputChange(async ({setList}) => {
          await leap.showLoading();
          await new Promise(resolve => setTimeout(resolve, 2000));
          await leap.hideLoading();
          setList(Array.from({length:11}, (_,i) => ({id:String(i),title:'结果 '+i,
            description:i === 0 ? '   ' : ('这是条目子标题 '+i+' ').repeat(20)})),
            {title:'共11个结果 '+ '很长的顶部标题'.repeat(40)});
        });
        leap.onSelect(async ({item}) => {
          await leap.showLoading();
          await new Promise(resolve => setTimeout(resolve, 2000));
          return '已选择 '+item.id;
        });
        """
        let app = try launch(source: "NumberEnumeration", openPlugin: true, script: script)
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        let first = app.buttons["plugin.result.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // 启动和辅助功能快照可能超过首次查询时间，主动触发查询再检查加载布局。
        let listFrame = app.descendants(matching: .any)["plugin.results"].firstMatch.frame
        let panelFrame = app.dialogs["com.padding.leap.launcher"].frame
        parameter.typeText("1")
        assertLoadingRing(app)
        XCTAssertEqual(app.descendants(matching: .any)["plugin.results"].firstMatch.frame, listFrame)
        XCTAssertEqual(app.dialogs["com.padding.leap.launcher"].frame, panelFrame)
        let queryFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: first
        )
        XCTAssertEqual(XCTWaiter.wait(for: [queryFinished], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["plugin.loadingIndicator"].exists)
        let title = app.staticTexts["plugin.listTitle"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.width, app.dialogs["com.padding.leap.launcher"].frame.width)
        XCTAssertLessThan(title.frame.height, 30)
        XCTAssertTrue(first.label.contains("⌘1"))
        XCTAssertFalse(first.label.contains("条目子标题"))
        XCTAssertTrue(app.buttons["plugin.result.1"].label.contains("这是条目子标题 1"))
        XCTAssertLessThan(app.buttons["plugin.result.1"].frame.height, 85)
        // 第十项在滚动区域之外，验证快捷键由窗口处理而非行是否已挂载。
        parameter.typeKey("0", modifierFlags: .command)
        assertLoadingRing(app)
        let selected = app.staticTexts["plugin.listFeedback"]
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "已选择 9", "已选择 9"), object: selected
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["plugin.loadingIndicator"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["launcher.searchField"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSharedListContentHeightAndScrolling() throws {
        let script = """
        leap.onInputChange(({text:input,setList}) => {
          const count = parseInt(input || '1', 10);
          setList(Array.from({length:count}, (_,i) => ({id:String(i),title:'结果 '+i,
            description:input.includes('long') ? '很长的子标题内容'.repeat(40) : '   '})));
        });
        """
        let app = try launch(source: "NumberEnumeration", openPlugin: true, script: script)
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        for input in ["1", "3", "3long", "7", "8", "9", "7", "100", "0", "3", "8", "0", "3"] {
            let count = Int(input.replacingOccurrences(of: "long", with: ""))!
            parameter.click()
            parameter.typeKey("a", modifierFlags: .command)
            parameter.typeText(input)
            let list = app.descendants(matching: .any)["plugin.results"].firstMatch
            if count == 0 {
                XCTAssertTrue(app.staticTexts["plugin.emptyResults"].waitForExistence(timeout: 5))
            } else {
                let expected = min(CGFloat(count * 52 + (count - 1) * 4), 444)
                let settled = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        list.exists && (input.hasSuffix("long")
                            ? list.frame.height > expected && list.frame.height <= 444
                            : abs(list.frame.height - expected) < 1)
                    }, object: nil
                )
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, "input=\(input), height=\(list.exists ? list.frame.height : -1)\n\(app.debugDescription)")
            }
        }
    }

    @MainActor
    func testNumberEnumerationSameCountKeepsLayoutAndInputFocus() throws {
        let app = try launch(source: "NumberEnumeration", openPlugin: true)
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        parameter.typeText("7")
        let first = app.buttons["plugin.result.0"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let list = app.descendants(matching: .any)["plugin.results"].firstMatch
        let panel = app.dialogs["com.padding.leap.launcher"]
        let listFrame = list.frame
        let panelFrame = panel.frame
        let rowFrame = first.frame
        // 不再点击输入框，验证更新列表后输入焦点仍留在参数框。
        for input in ["16", "25", "7"] {
            parameter.typeKey("a", modifierFlags: .command)
            parameter.typeText(input)
            let subtitle = app.staticTexts["plugin.subtitle.0"]
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ OR value == %@", "输入：\(input)", "输入：\(input)"),
                object: subtitle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
            XCTAssertEqual(list.frame, listFrame)
            XCTAssertEqual(panel.frame, panelFrame)
            XCTAssertEqual(first.frame, rowFrame)
        }
    }

    @MainActor
    func testDefaultSearchNumericShortcutEntersPlugin() throws {
        let app = try launch(source: "TextConvert")
        let search = app.textFields["launcher.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("convert")
        XCTAssertTrue(app.descendants(matching: .any)["launcher.searchResults"].firstMatch.waitForExistence(timeout: 5))
        search.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.textFields["plugin.parameterInput"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSDKCopyExitAndHide() throws {
        let previousText = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previousText { NSPasteboard.general.setString(previousText, forType: .string) }
        }
        let script = """
        leap.onInputChange(({setList}) => setList([
          {id:'copy',title:'复制'}, {id:'exit',title:'退出'}, {id:'hide',title:'隐藏'}
        ]));
        leap.onSelect(async ({item}) => {
          if (item.id === 'copy') { await leap.copyText('Leap SDK 测试'); return '已复制'; }
          if (item.id === 'exit') await leap.outPlugin();
          if (item.id === 'hide') await leap.hideMainWindow();
        });
        """
        let app = try launch(source: "NumberEnumeration", openPlugin: true, script: script)
        XCTAssertTrue(app.buttons["plugin.result.copy"].waitForExistence(timeout: 5))
        app.buttons["plugin.result.copy"].click()
        XCTAssertTrue(app.staticTexts["plugin.listFeedback"].waitForExistence(timeout: 5))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Leap SDK 测试")
        app.buttons["plugin.result.exit"].click()
        let search = app.textFields["launcher.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("number")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["plugin.result.hide"].waitForExistence(timeout: 5))
        app.buttons["plugin.result.hide"].click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.textFields["plugin.parameterInput"].exists)
    }

    @MainActor
    func testNumberEnumerationListAndSelection() throws {
        // 实机测试会写系统剪贴板，结束后恢复原有全部格式的数据。
        let previousItems: [NSPasteboardItem] = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let saved = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(previousItems)
        }
        // 使用真实示例经安装器校验并安装，覆盖清单到宿主列表的完整链路。
        let app = try launch(source: "NumberEnumeration", openPlugin: true)
        let search = app.textFields["launcher.searchField"]
        let parameter = app.textFields["plugin.parameterInput"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["launcher.settingsButton"].exists)
        parameter.typeText("123")
        XCTAssertTrue(app.buttons["plugin.result.5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plugin.result.0"].label.contains("标题 0"))
        XCTAssertFalse(app.buttons["plugin.result.6"].exists)
        parameter.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let feedback = app.staticTexts["plugin.listFeedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.value as? String ?? feedback.label, "已复制：标题 1")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "标题 1")
        XCTAssertFalse(app.descendants(matching: .any)["plugin.loadingIndicator"].exists)
        parameter.typeKey("a", modifierFlags: .command)
        parameter.typeText("19")
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["plugin.result.0"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "")
    }

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
        let settingsWindow = app.descendants(matching: .any)["settings.window"].firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), app.debugDescription)
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
        pluginName: String? = nil, inputEnabled: Bool = true, openPlugin: Bool = false, script: String? = nil
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
                window.leap.onInputChange(({ text }) => document.getElementById('input').textContent = 'input ' + text);
                window.leap.onSubmit(value => document.getElementById('submit').textContent = 'submit ' + value);
                </script></body></html>
                """
                try Data(html.utf8).write(to: directory.appendingPathComponent("index.html"))
            }
            manifest["commands"] = [command]
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        }
        if let script { try Data(script.utf8).write(to: directory.appendingPathComponent("main.js")) }
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

private extension PluginInteractionUITests {
    @MainActor
    func assertLoadingRing(_ app: XCUIApplication) {
        let ring = app.descendants(matching: .any)["plugin.loadingIndicator"]
        XCTAssertTrue(ring.waitForExistence(timeout: 5), app.debugDescription)
        // 圆弧的辅助功能边界随旋转角度变化，不等同于固定 32pt 的布局框。
        XCTAssertGreaterThan(ring.frame.width, 24)
        XCTAssertLessThanOrEqual(ring.frame.width, 34)
        XCTAssertGreaterThan(ring.frame.height, 24)
        XCTAssertLessThanOrEqual(ring.frame.height, 34)
        XCTAssertLessThan(ring.frame.maxX, app.textFields["plugin.parameterInput"].frame.minX)
        XCTAssertFalse(app.activityIndicators["plugin.queryProgress"].exists)
        XCTAssertFalse(app.activityIndicators["plugin.selectionProgress"].exists)
    }

}
