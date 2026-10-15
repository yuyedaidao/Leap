import Foundation

/// 设置页只检索插件清单，不执行命令或读取插件运行数据。
public struct PluginLibraryQuery {
    public enum Source: String, CaseIterable, Sendable {
        case all, local, official
    }

    public var searchText: String
    public var source: Source

    public init(searchText: String = "", source: Source = .all) {
        self.searchText = searchText
        self.source = source
    }

    public var term: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func includes(_ plugin: InstalledPluginDescriptor) -> Bool {
        guard source == .all || (source == .local && plugin.origin == .local)
            || (source == .official && plugin.origin == .official) else { return false }
        return term.isEmpty || plugin.manifest.name.localizedStandardContains(term)
            || plugin.id.localizedStandardContains(term) || !matchingCommands(in: plugin).isEmpty
    }

    public func matchingCommands(in plugin: InstalledPluginDescriptor) -> [PluginManifest.Command] {
        guard !term.isEmpty else { return [] }
        return plugin.manifest.commands.filter { command in
            command.title.localizedStandardContains(term)
                || (command.keywords ?? []).contains { $0.localizedStandardContains(term) }
        }
    }
}
