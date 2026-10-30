import Foundation
import Testing
@testable import LeapCore

struct SearchTextIndexTests {
    @Test("应用与插件使用相同的检索等级", arguments: [
        ("剪切板", "jianqieban"), ("剪切板", "jqb"), ("剪切板", "jq"),
        ("剪切板", "jianqb"), ("剪切板", "jqieban"), ("剪切板", "jianqi"),
        ("Visual Studio Code", "vsc"), ("Visual Studio Code", "vs"),
        ("ClipBoard Manager", "cbm"), ("XMLParser", "xp"),
        ("Visual-Studio_Code", "vsc"), ("微信 DevTools", "wxdt"), ("微信 DevTools", "weixindt"),
        ("剪切板", "ＪＱＢ"), ("剪切板", "JIĀNQIEBAN"), ("剪切板", " j-q-b ")
    ])
    func sharedRanks(name: String, query: String) throws {
        let index = SearchTextIndex(name)
        let rank = try #require(index.matchRank(for: query))
        let application = SystemApplicationDescriptor(
            name: name, bundleIdentifier: nil, url: URL(filePath: "/Test.app")
        )
        let plugin = PluginCommandMatcher(command: .init(id: "test", title: name))
        #expect(application.matchRank(for: query) == rank)
        #expect(plugin.keywordMatchRank(for: query) == rank)
    }

    @Test("不跨字、不乱序、不跨别名组合", arguments: ["", "  ", "---", "jb", "qjb", "jianban", "nope"])
    func rejects(query: String) {
        #expect(SearchTextIndex("剪切板").matchRank(for: query) == nil)
    }

    @Test("每个别名、关键词与插件名称独立参与最佳等级匹配")
    func aliasesAndKeywords() {
        let application = SystemApplicationDescriptor(
            name: "Clipboard", bundleIdentifier: "org.example.clipboard", url: URL(filePath: "/Test.app"),
            alternateNames: ["剪切板", "Visual Studio Code"]
        )
        let plugin = PluginCommandMatcher(
            command: .init(id: "clipboard.history", title: "Clipboard", keywords: ["剪贴板", "Visual Studio Code"]),
            pluginName: "剪切板"
        )
        for query in ["jqb", "jianqb", "vsc", "clipboard"] {
            #expect(application.matchRank(for: query) == plugin.keywordMatchRank(for: query))
        }
        #expect(plugin.keywordMatchRank(for: "jtb") != nil)
        #expect(plugin.keywordMatchRank(for: "jqbvsc") == nil)
        #expect(application.matchRank(for: "jqbvsc") == nil)
        #expect(plugin.keywordMatchRank(for: "clipboard.history") == SearchMatchRank.identifierExact.rawValue)
        #expect(application.matchRank(for: "org.example.clipboard") == SearchMatchRank.identifierExact.rawValue)
    }

    @Test("应用别名去重保留不同分词，系统转写保留多音字上下文")
    func wordBoundariesAndContext() {
        let application = SystemApplicationDescriptor(
            name: "visualstudiocode", bundleIdentifier: nil, url: URL(filePath: "/Test.app"),
            alternateNames: ["Visual Studio Code", "Visual Studio Code"]
        )
        #expect(application.alternateNames == ["Visual Studio Code"])
        #expect(application.matchRank(for: "vsc") == SearchMatchRank.initialsExact.rawValue)
        #expect(SearchTextIndex("重庆").pinyin == "chongqing")
    }

    @Test("相关度等级在应用与插件之间统一")
    func ordering() throws {
        let index = SearchTextIndex("剪切板")
        let queries = ["剪切板", "剪切", "切板", "jianqieban", "jianqie", "qieban", "jqb", "jq", "jianqb"]
        let ranks = try queries.map { try #require(index.matchRank(for: $0)) }
        #expect(ranks == Array(0...8))
        #expect(SearchMatchRank.mixed.rawValue < SearchMatchRank.identifierExact.rawValue)
        #expect(SearchMatchRank.identifierContains.rawValue < SearchMatchRank.content.rawValue)
    }

    @Test("内容规则不受名称检索影响，刷新构造新索引")
    func contentAndRefresh() {
        let command = PluginManifest.Command(
            id: "history", title: "剪切板", keywords: ["剪贴板"], matches: [.init(type: .text)]
        )
        let matcher = PluginCommandMatcher(command: command)
        #expect(matcher.matchesContent("jianqb"))
        #expect(matcher.keywordMatchRank(for: "jianqb") != nil)
        #expect(matcher.matchesContent("other input"))
        #expect(matcher.keywordMatchRank(for: "other input") == nil)
        let refreshed = PluginCommandMatcher(command: .init(id: "history", title: "计算器"))
        #expect(refreshed.keywordMatchRank(for: "jqb") == nil)
        #expect(refreshed.keywordMatchRank(for: "jsq") != nil)
    }

    @Test("长名称混合匹配与缓存往返保留新索引")
    func longNameAndCache() throws {
        let name = String(repeating: "剪切板", count: 100)
        let query = String(repeating: "jianqb", count: 99) + "jianq"
        let application = SystemApplicationDescriptor(
            name: name, bundleIdentifier: nil, url: URL(filePath: "/Test.app")
        )
        #expect(application.matchRank(for: query) == SearchMatchRank.mixed.rawValue)
        #expect(application.matchRank(for: query + "z") == nil)
        let cached = try JSONDecoder().decode(SystemApplicationDescriptor.self, from: JSONEncoder().encode(application))
        #expect(cached == application)
        #expect(cached.matchRank(for: query) == application.matchRank(for: query))
        #expect(SearchTextIndex("").matchRank(for: "abc") == nil)
        #expect(SearchTextIndex("---").matchRank(for: "abc") == nil)
    }
}
