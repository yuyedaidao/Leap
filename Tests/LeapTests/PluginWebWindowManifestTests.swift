import Foundation
import Testing
@testable import LeapCore

struct PluginWebWindowManifestTests {
    @Test("旧清单兼容，新尺寸可编解码且保留未知字段兼容性")
    func roundTrip() throws {
        let old = try JSONDecoder().decode(PluginManifest.self, from: data(size: nil))
        #expect(old.webWindow == nil)
        let sized = try JSONDecoder().decode(PluginManifest.self, from: data(size: ["width": 800, "height": 600]))
        #expect(sized.webWindow == .init(width: 800, height: 600))
        #expect(try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(sized)) == sized)
    }

    @Test("尺寸必须同时提供宽高且使用整数")
    func malformed() throws {
        let sizes: [[String: Any]] = [
            ["width": 800], ["height": 600], ["width": "800", "height": 600],
            ["width": 800.5, "height": 600], ["width": true, "height": 600]
        ]
        for size in sizes {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PluginManifest.self, from: data(size: size))
            }
        }
    }

    @Test("拒绝非正数、过小尺寸及无网页入口的配置", arguments: [
        (0, 600, true), (-1, 600, true), (800, 0, true), (399, 600, true),
        (800, 299, true), (800, 600, false), (400, 300, true), (100_000, 100_000, true)
    ])
    func validation(width: Int, height: Int, withUI: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("main.js"))
        try Data().write(to: directory.appendingPathComponent("index.html"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data(
            size: ["width": width, "height": height], withUI: withUI
        ))
        if withUI, width >= 400, height >= 300 {
            try PluginManifestValidator().validate(manifest, in: directory)
        } else {
            #expect(throws: PluginManifestValidator.ValidationError.invalidWebWindow) {
                try PluginManifestValidator().validate(manifest, in: directory)
            }
        }
    }

    @Test("独立窗口示例通过实际清单校验并能调用脚本")
    func standaloneWindowExample() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Examples/Plugins/StandaloneWindow")
        let manifest = try PluginManifestValidator().load(from: directory)
        let command = try #require(manifest.commands.first)
        // 宿主以未声明 mode 且存在 webEntry 的组合选择独立窗口路由。
        #expect(command.mode == nil)
        #expect(command.presentation == nil)
        #expect(command.input == nil)
        #expect(manifest.webEntry == "index.html")
        #expect(manifest.webWindow == .init(width: 800, height: 600))
        let process = PluginProcessSession(
            executable: root.appendingPathComponent("Resources/Leap/Runtimes/node-24.21.0/bin/node"),
            arguments: [root.appendingPathComponent("Resources/Leap/PluginSDK/bootstrap.cjs").path,
                        directory.appendingPathComponent(manifest.entry).path],
            hostCall: { _, _ in .bool(true) }
        )
        defer { process.close() }
        _ = try await process.request("enter", commandID: command.id, query: "")
        #expect(try await process.request("invoke", commandID: command.id, query: "").string
            == "你好，这是独立窗口中的脚本返回结果！")
        await #expect(throws: (any Error).self) {
            try await process.request("invoke", commandID: "unknown", query: "")
        }
        #expect(try await process.request("invoke", commandID: command.id, query: "").string
            == "你好，这是独立窗口中的脚本返回结果！")
    }

    private func data(size: [String: Any]?, withUI: Bool = true) throws -> Data {
        var object: [String: Any] = [
            "id": "com.example.window", "name": "窗口", "version": "1.0.0",
            "runtime": "javascript", "entry": "main.js",
            "commands": [["id": "run", "title": "运行"]]
        ]
        if withUI { object["webEntry"] = "index.html" }
        if let size { object["webWindow"] = size }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
