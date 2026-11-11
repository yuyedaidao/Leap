import Foundation
import Testing

@testable import LeapCore

struct PluginStoreIndexTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let validEntry = """
        {
          "id": "com.padding.leap.json-formatter",
          "name": "JSON 格式化",
          "version": "1.1.0",
          "summary": "粘贴 JSON 自动格式化",
          "path": "plugins/json-formatter",
          "runtime": "javascript",
          "minimumHostVersion": "0.0.2",
          "commands": ["JSON 格式化"]
        }
        """

    @Test("合法索引按条目解码并保留顺序")
    func decodeValid() throws {
        let index = try PluginStoreIndex.decode(
            data("""
                {"schemaVersion": 1, "name": "Leap 官方插件", "plugins": [\(validEntry)]}
                """))
        #expect(index.name == "Leap 官方插件")
        #expect(index.plugins.count == 1)
        let entry = try #require(index.plugins.first)
        #expect(entry.path == "plugins/json-formatter")
        #expect(entry.commands == ["JSON 格式化"])
        #expect(index.entry(id: "com.padding.leap.json-formatter") == entry)
    }

    @Test("缺少必填字段或格式错误整份索引不可用")
    func decodeMalformed() {
        #expect(throws: PluginStoreError.invalidIndex) {
            try PluginStoreIndex.decode(data(#"{"plugins": []}"#))
        }
        #expect(throws: PluginStoreError.invalidIndex) {
            try PluginStoreIndex.decode(data(#"{"schemaVersion": 1, "plugins": [{"id": "a", "name": "b"}]}"#))
        }
        #expect(throws: PluginStoreError.invalidIndex) {
            try PluginStoreIndex.decode(data("not json"))
        }
    }

    @Test("不支持的索引版本被拒绝")
    func decodeSchema() {
        #expect(throws: PluginStoreError.unsupportedSchema) {
            try PluginStoreIndex.decode(data(#"{"schemaVersion": 2, "plugins": []}"#))
        }
    }

    @Test("重复 ID、内置 ID 与非法路径只跳过该条")
    func decodeSkipsInvalidEntries() throws {
        let index = try PluginStoreIndex.decode(
            data("""
                {"schemaVersion": 1, "plugins": [
                  \(validEntry),
                  \(validEntry),
                  {"id": "com.padding.leap.shutdown", "name": "关机", "version": "1.0.0", "path": "/plugins/shutdown"},
                  {"id": "com.padding.leap.template-generator", "name": "模板", "version": "1.0.0", "path": "plugins/t"},
                  {"id": "com.padding.leap.escape", "name": "越界", "version": "1.0.0", "path": "plugins/../../etc"},
                  {"id": " ", "name": "空 ID", "version": "1.0.0", "path": "plugins/empty"}
                ]}
                """))
        #expect(index.plugins.map(\.id) == ["com.padding.leap.json-formatter"])
    }

    @Test(
        "状态按版本比较判定，只有更高版本可更新",
        arguments: [
            (nil, PluginStoreEntry.State.notInstalled), ("1.1.0", .installed), ("1.2.0", .installed),
            ("1.0.9", .updatable)
        ])
    func state(installed: String?, expected: PluginStoreEntry.State) throws {
        let entry = try #require(
            try PluginStoreIndex.decode(data("""
                {"schemaVersion": 1, "plugins": [\(validEntry)]}
                """)).plugins.first)
        #expect(entry.state(installedVersion: installed) == expected)
    }

    @Test("安装地址由来源与目录拼成")
    func installAddress() throws {
        let entry = try #require(
            try PluginStoreIndex.decode(data("""
                {"schemaVersion": 1, "plugins": [\(validEntry)]}
                """)).plugins.first)
        let source = PluginStoreSource.official
        #expect(
            entry.installAddress(source: source)
                == "https://github.com/yuyedaidao/LeapPlugins/tree/main/plugins/json-formatter")
        let parsed = try GitHubPluginAddress(entry.installAddress(source: source))
        #expect(parsed.referenceAndPath == ["main", "plugins", "json-formatter"])
        #expect(
            source.indexURL.absoluteString
                == "https://raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json")
    }

    @Test("最低宿主版本不合规的条目不提供安装")
    func compatibility() {
        func entry(_ minimum: String?) -> PluginStoreEntry {
            PluginStoreEntry(id: "a", name: "a", version: "1", path: "p", minimumHostVersion: minimum)
        }
        #expect(entry(nil).isCompatibleWithHost())
        #expect(entry("0.0.1").isCompatibleWithHost())
        #expect(!entry("99.0.0").isCompatibleWithHost())
        // 三段数字之外的值与清单校验一样视为无效。
        #expect(!entry("1.0").isCompatibleWithHost())
    }
}
