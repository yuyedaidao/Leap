import Foundation

/// 应用和插件共用的相关度；历史记录只参与同等级排序。
public enum SearchMatchRank: Int, Sendable {
    case textExact, textPrefix, textContains
    case pinyinExact, pinyinPrefix, pinyinContains
    case initialsExact, initialsPrefix, mixed
    case identifierExact, identifierPrefix, identifierContains, content
}

/// 每个名称独立建索引，避免跨别名拼接；转写和分词不进入按键处理路径。
public struct SearchTextIndex: Codable, Hashable, Sendable {
    public let normalized: String
    public let pinyin: String
    public let initials: String
    private let tokens: [String]

    // Regex 不符合 Sendable，只在建索引时创建，避免共享可变状态。
    // 先识别缩写末尾与普通单词的边界：XMLParser → XML、Parser。
    private static var words: Regex<Substring> {
        // swiftlint:disable:next opening_brace
        /\p{Han}+|[A-Z]+(?=[A-Z][a-z]|[^A-Za-z]|$)|[A-Z]?[a-z]+|[A-Z]+|[0-9]+|[\p{L}\p{M}]+/
    }

    public init(_ text: String) {
        normalized = Self.normalize(text)
        let folded = text.folding(
            options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        tokens = folded.matches(of: Self.words).flatMap { match -> [String] in
            let word = String(match.output)
            let latin = word.applyingTransform(.toLatin, reverse: false) ?? word
            if word.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) {
                // 整段转写保留多音字的上下文；系统未按字分音节时再逐字回退。
                let syllables = latin.split(whereSeparator: \.isWhitespace).map { Self.normalize(String($0)) }
                if syllables.count == word.count, syllables.allSatisfy({ !$0.isEmpty }) { return syllables }
                return word.map { Self.normalize(String($0).applyingTransform(.toLatin, reverse: false) ?? String($0)) }
            }
            return [Self.normalize(latin)]
        }.filter { !$0.isEmpty }
        pinyin = tokens.joined()
        initials = tokens.compactMap(\.first).map(String.init).joined()
    }

    public static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    public func matchRank(for query: String) -> Int? {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return nil }
        return Self.rank(normalized, query: query, exact: .textExact, prefix: .textPrefix, contains: .textContains)
            ?? Self.rank(pinyin, query: query, exact: .pinyinExact, prefix: .pinyinPrefix, contains: .pinyinContains)
            ?? Self.rank(initials, query: query, exact: .initialsExact, prefix: .initialsPrefix)
            ?? (matchesMixed(query) ? SearchMatchRank.mixed.rawValue : nil)
    }

    public static func identifierRank(_ identifier: String?, for query: String) -> Int? {
        let query = normalize(query)
        guard !query.isEmpty else { return nil }
        return rank(normalize(identifier ?? ""), query: query,
                    exact: .identifierExact, prefix: .identifierPrefix, contains: .identifierContains)
    }

    private static func rank(
        _ key: String, query: String, exact: SearchMatchRank, prefix: SearchMatchRank,
        contains: SearchMatchRank? = nil
    ) -> Int? {
        guard !key.isEmpty else { return nil }
        if key == query { return exact.rawValue }
        if key.hasPrefix(query) { return prefix.rawValue }
        if let contains, key.contains(query) { return contains.rawValue }
        return nil
    }

    private func matchesMixed(_ query: String) -> Bool {
        let query = Array(query.utf8)
        guard query.count <= pinyin.utf8.count else { return false }
        // 状态只保留消费到的查询位置，不展开每个字的全拼/首字母组合。
        var positions: Set<Int> = [0]
        for token in tokens {
            var next = Set<Int>()
            let spelling = Array(token.utf8)
            let initial = Array(String(token.prefix(1)).utf8)
            for position in positions {
                let remaining = query[position...]
                if spelling.starts(with: remaining) { return true }
                for option in [spelling, initial] where remaining.starts(with: option) {
                    let end = position + option.count
                    if end == query.count { return true }
                    next.insert(end)
                }
            }
            guard !next.isEmpty else { return false }
            positions = next
        }
        return false
    }
}
