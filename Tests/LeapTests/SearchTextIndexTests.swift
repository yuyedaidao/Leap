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
        // 本名与插件关键词同级；应用的非首选语言别名（CFBundleName、其它语言 loctable）只做兜底。
        #expect(application.matchRank(for: "clipboard") == plugin.keywordMatchRank(for: "clipboard"))
        for query in ["jqb", "jianqb", "vsc"] {
            #expect(application.matchRank(for: query)
                == plugin.keywordMatchRank(for: query).map { $0 + SearchMatchRank.aliasOffset })
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
        // 分词形态只存在于别名里，因此落回兜底梯队。
        #expect(application.matchRank(for: "vsc")
            == SearchMatchRank.initialsExact.rawValue + SearchMatchRank.aliasOffset)
        #expect(SearchTextIndex("重庆").pinyin == "chongqing")
    }

    @Test("相关度等级在应用与插件之间统一")
    func ordering() throws {
        let index = SearchTextIndex("剪切板")
        let queries = ["剪切板", "剪切", "切板", "jianqieban", "jianqie", "qieban", "jqb", "jq", "jianqb"]
        let ranks = try queries.map { try #require(index.matchRank(for: $0)) }
        // 完全匹配一律高于包含：完整首字母（jqb）> 拼音前缀 > 拼音包含。
        #expect(ranks == [0, 1, 2, 4, 6, 7, 3, 5, 8])
        #expect(SearchMatchRank.initialsExact.rawValue < SearchMatchRank.pinyinContains.rawValue)
        #expect(SearchMatchRank.mixed.rawValue < SearchMatchRank.identifierExact.rawValue)
        #expect(SearchMatchRank.identifierContains.rawValue < SearchMatchRank.content.rawValue)
    }

    @Test("完整首字母压过其他名称的拼音子串")
    func initialsBeatPinyinContains() {
        let wechat = SearchTextIndex("微信")
        let preview = SearchTextIndex("预览")
        let wechatRank = wechat.matchRank(for: "wx")
        #expect(wechatRank == SearchMatchRank.initialsExact.rawValue)
        #expect(preview.matchRank(for: "wx") == nil)
    }

    @Test("非首选语言别名不能压过本名匹配")
    func primaryNameBeatsLocalizedAliases() {
        let dictionary = SystemApplicationDescriptor(
            name: "词典", bundleIdentifier: "com.apple.Dictionary", url: URL(filePath: "/Applications/Dictionary.app"),
            alternateNames: ["Dictionary", "Wörterbuch", "Diccionario"]
        )
        // 德语名的 sync-Dienstprogramm 蕴含 cd 子串，不能因此排到「词典」前面。
        let colorSync = SystemApplicationDescriptor(
            name: "色彩同步实用工具", bundleIdentifier: "com.apple.ColorSyncUtility",
            url: URL(filePath: "/Applications/ColorSync Utility.app"),
            alternateNames: ["ColorSync-Dienstprogramm"]
        )
        let dictionaryRank = dictionary.matchRank(for: "cd")
        #expect(dictionaryRank == SearchMatchRank.initialsExact.rawValue)
        #expect((dictionaryRank ?? .max) < (colorSync.matchRank(for: "cd") ?? .max))
    }

    @Test("非汉字、非拉丁脚本只做字面匹配")
    func nonLatinScriptsSkipTransliteration() {
        let thai = SearchTextIndex("แสดงตัวอย่าง")
        #expect(thai.pinyin.isEmpty)
        #expect(thai.initials.isEmpty)
        #expect(thai.matchRank(for: "wx") == nil)
        #expect(thai.matchRank(for: "แสดงตัวอย่าง") == SearchMatchRank.textExact.rawValue)
        let cyrillic = SearchTextIndex("Терминал")
        #expect(cyrillic.pinyin.isEmpty)
        #expect(cyrillic.matchRank(for: "terminal") == nil)
        #expect(cyrillic.matchRank(for: "терминал") == SearchMatchRank.textExact.rawValue)
        // 扩展拉丁字母仍参与转写，只跳过非拉丁脚本。
        #expect(SearchTextIndex("Straße").pinyin == "strasse")
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
