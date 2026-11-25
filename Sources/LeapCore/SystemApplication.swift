import Foundation
@preconcurrency import YQLogger

public struct SystemApplicationDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    /// 显示用名称：与 Finder 看到的字一致（系统语言本地化名，否则包名）。检索只用 `name`。
    public let displayName: String?
    public let alternateNames: [String]
    public let bundleIdentifier: String?
    public let path: String
    public let normalizedName: String
    public let pinyin: String
    public let pinyinInitials: String
    private let searchIndexes: [SearchTextIndex]

    /// 路径唯一：同一 Bundle ID 可能存在多份副本（如多个 Xcode 版本）。
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var historyKey: String { path }

    public init(
        name: String,
        bundleIdentifier: String?,
        url: URL,
        alternateNames: [String] = [],
        displayName: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        path = url.standardizedFileURL.resolvingSymlinksInPath().path
        normalizedName = Self.normalize(name)

        // 同一原文可能有不同分词（visualstudiocode / Visual Studio Code），不能只按去空格名称去重。
        let primaryIndex = SearchTextIndex(name)
        var indexes = [primaryIndex]
        var indexedNames: Set<SearchTextIndex> = [primaryIndex]
        self.alternateNames = alternateNames.filter { alternateName in
            let index = SearchTextIndex(alternateName)
            guard !index.normalized.isEmpty, indexedNames.insert(index).inserted else { return false }
            indexes.append(index)
            return true
        }
        searchIndexes = indexes
        pinyin = searchIndexes[0].pinyin
        pinyinInitials = searchIndexes[0].initials
    }

    /// 数值越小表示文本匹配越直接，调用方再以使用记录解决同级排序。
    /// 非首选语言的别名（loctable 里的几十种外语名字）只做兜底：任何本名匹配都排在它们之前。
    public func matchRank(for query: String) -> Int? {
        let primary = [searchIndexes[0].matchRank(for: query),
                       SearchTextIndex.identifierRank(bundleIdentifier, for: query)].compactMap { $0 }.min()
        if let primary { return primary }
        return searchIndexes.dropFirst().compactMap { $0.matchRank(for: query) }.min()
            .map { $0 + SearchMatchRank.aliasOffset }
    }

    public static func normalize(_ value: String) -> String {
        SearchTextIndex.normalize(value)
    }

}

public struct SystemApplicationScanner: Sendable {
    private static let logger = YQLogger(label: "com.padding.leap/application-scanner")

    public static let defaultRoots = [
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
    ]

    public let roots: [URL]
    private let preferredLanguages: [String]

    public init(roots: [URL] = Self.defaultRoots) {
        self.init(
            roots: roots,
            preferredLanguages: UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        )
    }

    init(roots: [URL], preferredLanguages: [String]) {
        self.roots = roots.map(\.standardizedFileURL)
        self.preferredLanguages = preferredLanguages
    }

    public func scan(fileManager: FileManager = .default) -> [SystemApplicationDescriptor] {
        var result: [SystemApplicationDescriptor] = []
        // roots 的顺序定义重复 Bundle ID 的优先级：用户、全局、系统。
        var claimedIdentifiers: Set<String> = []
        for root in roots {
            // 同一 root 内同 Bundle ID 的不同副本（Xcode 多版本）都要保留，只按路径去重。
            var rootIdentifiers: Set<String> = []
            var rootPaths: Set<String> = []
            for application in applications(in: root, fileManager: fileManager) {
                let key = application.bundleIdentifier ?? application.path
                guard !claimedIdentifiers.contains(key), rootPaths.insert(application.path).inserted else { continue }
                rootIdentifiers.insert(key)
                result.append(application)
            }
            claimedIdentifiers.formUnion(rootIdentifiers)
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func applications(in root: URL, fileManager: FileManager) -> [SystemApplicationDescriptor] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        if root.pathExtension == "app" {
            return descriptor(for: root, fileManager: fileManager).map { [$0] } ?? []
        }
        // 不能用 .skipsHiddenFiles：它会在产出阶段就丢掉带 UF_HIDDEN 标志的 .app（Safari 的
        // /Applications/Safari.app 就是隐藏符号链接），后续解析别名和读取 Bundle 都来不及执行。
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [SystemApplicationDescriptor] = []
        for case let sourceURL as URL in enumerator {
            let url = resolvedApplicationURL(for: sourceURL)
            guard url.pathExtension == "app" else {
                // 隐藏的普通目录与文件仍然跳过其后代，避免扫描大量噪声。
                if isHidden(sourceURL) {
                    enumerator.skipDescendants()
                }
                continue
            }
            enumerator.skipDescendants()
            guard let descriptor = descriptor(for: url, fileManager: fileManager) else { continue }
            result.append(descriptor)
        }
        return result
    }

    private func isHidden(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }

    private func resolvedApplicationURL(for url: URL) -> URL {
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true else { return url }
        return (try? URL(resolvingAliasFileAt: url, options: [])) ?? url
    }

    private func descriptor(for url: URL, fileManager: FileManager) -> SystemApplicationDescriptor? {
        // 不能按 CFBundlePackageType 白名单过滤：系统应用的包类型并不都是 APPL，
        // 访达是 FNDR、密码是 XPC!，白名单会持续漏掉下一类系统应用。
        guard !url.lastPathComponent.hasPrefix("."),
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary,
              (info["LSBackgroundOnly"] as? Bool) != true,
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path)
        else {
            return nil
        }

        let localizedNames = localizedNames(in: bundle)
        let allLocalizedNames = localizedNames.preferred + localizedNames.others
        // 不调用 localizedInfoDictionary：损坏的 loctable 可能触发无法用 Swift catch 捕获的系统异常。
        let localizedInfo = allLocalizedNames.isEmpty
            ? propertyListDictionary(at: bundle.url(forResource: "InfoPlist", withExtension: "strings")) : [:]
        // CFBundleDisplayName 可能被显式写成空串（如 Copilot for Xcode），空串不能当中文名用。
        let candidates = [
            allLocalizedNames.first,
            localizedInfo["CFBundleDisplayName"] as? String,
            localizedInfo["CFBundleName"] as? String,
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String
        ].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Finder 规则：没有当前系统语言的本地化名时显示包名（Xcode-27.2.0.app → Xcode-27.2.0）。
        let packageName = url.deletingPathExtension().lastPathComponent
        let name = candidates.first ?? packageName
        let displayName = localizedNames.preferred.first ?? packageName
        let alternateNames = [
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String
        ].compactMap { $0 } + allLocalizedNames
        return SystemApplicationDescriptor(
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            url: url,
            alternateNames: alternateNames,
            displayName: displayName == name ? nil : displayName
        )
    }

    /// 本地化名称按「是否命中系统语言」分成两组：`preferred` 决定显示名，`others` 只作搜索别名。
    private func localizedNames(in bundle: Bundle) -> (preferred: [String], others: [String]) {
        // 系统应用可能只在 loctable 中保存名称；每次扫描只解析一次，共享给各语言。
        let table = propertyListDictionary(at: bundle.url(forResource: "InfoPlist", withExtension: "loctable"))
        let tableLocalizations = table.keys.filter {
            $0 != "LocProvenance" && $0 != "NonLocalized" && table[$0] is [String: Any]
        }
        let availableLocalizations = Set(bundle.localizations + tableLocalizations).sorted()
        // 不能用 Bundle.preferredLocalizations 判断命中：系统语言缺失时它会回退到 en。
        let bundlePreferred = Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: preferredLanguages
        )
        let localizations = bundlePreferred + availableLocalizations.filter {
            !bundlePreferred.contains($0)
        }

        var preferred: [String] = []
        var others: [String] = []
        for localization in localizations {
            let strings = propertyListDictionary(at: bundle.url(
                forResource: "InfoPlist",
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            ))
            let localizedTable = table[localization] as? [String: Any] ?? [:]
            // 同语言沿用 strings 的优先级。
            let names = [strings, localizedTable].flatMap { info in
                [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String]
                    .compactMap { $0 }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            if matchesSystemLanguage(localization) {
                preferred.append(contentsOf: names)
            } else {
                others.append(contentsOf: names)
            }
        }
        return (preferred, others)
    }

    /// 只比较语言主码：系统语言 zh-Hans-CN 命中 zh_CN / zh-Hans，不命中 en。
    private func matchesSystemLanguage(_ localization: String) -> Bool {
        // 取不到系统语言时不做筛选，退化为沿用 Bundle 的语言顺序（否则标题会全部变成包名）。
        guard !preferredLanguages.isEmpty else { return true }
        let code = Self.languageCode(localization)
        guard !code.isEmpty else { return false }
        return preferredLanguages.contains { Self.languageCode($0) == code }
    }

    private static func languageCode(_ identifier: String) -> String {
        ((identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first).map(String.init) ?? "")
            .lowercased()
    }

    private func propertyListDictionary(at url: URL?) -> [String: Any] {
        guard let url else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] else {
                Self.logger.warning("忽略非字典格式的应用名称资源：\(url.path)。")
                return [:]
            }
            return dictionary
        } catch {
            Self.logger.warning("读取应用名称资源失败：\(url.path)，\(error.localizedDescription)。")
            return [:]
        }
    }
}

public enum SystemApplicationIndexCache {
    private struct Snapshot: Codable {
        let version: Int
        let applications: [SystemApplicationDescriptor]
    }

    // 检索字段和分词规则变化后使旧快照失效，避免继续使用旧拼音键。
    private static let version = 9

    public static func load(from url: URL, fileManager: FileManager = .default) -> [SystemApplicationDescriptor]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == version
        else {
            return nil
        }
        return snapshot.applications
    }

    public static func save(_ applications: [SystemApplicationDescriptor], to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Snapshot(version: version, applications: applications))
        try data.write(to: url, options: .atomic)
    }
}
