import Foundation

/// 商店只按索引字段过滤，不发额外请求。
public struct PluginStoreQuery: Equatable, Sendable {
    public var searchText: String

    public init(searchText: String = "") {
        self.searchText = searchText
    }

    public var term: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func includes(_ entry: PluginStoreEntry) -> Bool {
        guard !term.isEmpty else { return true }
        return entry.name.localizedStandardContains(term) || entry.id.localizedStandardContains(term)
            || (entry.summary?.localizedStandardContains(term) ?? false)
            || entry.commands.contains { $0.localizedStandardContains(term) }
    }
}
