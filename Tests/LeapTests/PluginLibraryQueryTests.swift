import Foundation
import Testing
@testable import LeapCore

struct PluginLibraryQueryTests {
    private func plugin(origin: InstalledPluginDescriptor.Origin = .local) -> InstalledPluginDescriptor {
        InstalledPluginDescriptor(
            manifest: PluginManifest(
                id: "test.project-tools", name: "Café 项目工具", version: "1.0.0", runtime: .javascript,
                entry: "main.js", commands: [
                    .init(id: "open", title: "打开目录", keywords: ["folder", "共享"]),
                    .init(id: "copy", title: "复制路径", keywords: ["path", "共享"]),
                    .init(id: "empty", title: "无关键字")
                ]
            ),
            pluginDirectory: URL(fileURLWithPath: "/unused"), iconURL: nil, origin: origin
        )
    }

    @Test("名称、ID、命令和关键字可检索，忽略大小写及两侧空白",
          arguments: ["CAFE", "项目工具", " PROJECT-TOOLS ", "打开", "FOLDER", "复制路径", "共享", " \n "])
    func matchingFields(term: String) {
        #expect(PluginLibraryQuery(searchText: term).includes(plugin()))
    }

    @Test("来源与关键词组合筛选，官方和本地不会互相泄漏")
    func sourceFilter() {
        let local = plugin()
        let official = plugin(origin: .official)
        #expect(PluginLibraryQuery().includes(local))
        #expect(PluginLibraryQuery().includes(official))
        #expect(PluginLibraryQuery(source: .local).includes(local))
        #expect(!PluginLibraryQuery(source: .local).includes(official))
        #expect(!PluginLibraryQuery(source: .official).includes(local))
        #expect(PluginLibraryQuery(searchText: "folder", source: .official).includes(official))
        #expect(!PluginLibraryQuery(searchText: "不存在", source: .official).includes(official))
    }

    @Test("命令匹配保留清单顺序，每个命令只返回一次，空搜索不生成匹配说明")
    func matchingCommandContext() {
        #expect(PluginLibraryQuery(searchText: "共享").matchingCommands(in: plugin()).map(\.id) == ["open", "copy"])
        #expect(PluginLibraryQuery(searchText: "无关键字").matchingCommands(in: plugin()).map(\.id) == ["empty"])
        #expect(PluginLibraryQuery().matchingCommands(in: plugin()).isEmpty)
        #expect(PluginLibraryQuery(searchText: "Café").matchingCommands(in: plugin()).isEmpty)
        #expect(!PluginLibraryQuery(searchText: "不存在").includes(plugin()))
    }
}
