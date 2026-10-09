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
