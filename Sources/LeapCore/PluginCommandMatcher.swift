import Foundation

/// 安装索引刷新时编译规则，输入变化时只匹配，不启动插件进程。
public struct PluginCommandMatcher {
    private let rules: [(PluginManifest.Command.Match, NSRegularExpression?)]

    public init(command: PluginManifest.Command) {
        rules = (command.matches ?? []).map { match in
            (match, match.pattern.flatMap { try? NSRegularExpression(pattern: $0) })
        }
    }

    public func matchesContent(_ text: String) -> Bool {
        guard !rules.isEmpty, text.count <= 10_000 else { return false }
        let length = text.count
        return rules.contains { match, expression in
            guard length >= (match.minLength ?? 1), length <= (match.maxLength ?? 1000) else { return false }
            return match.type == .text || expression?.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
            ) != nil
        }
    }
}
