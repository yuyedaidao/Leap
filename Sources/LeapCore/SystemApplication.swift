import Foundation
@preconcurrency import YQLogger

public struct SystemApplicationDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let alternateNames: [String]
    public let bundleIdentifier: String?
    public let path: String
    public let normalizedName: String
    public let pinyin: String
    public let pinyinInitials: String
    private let searchIndexes: [SearchTextIndex]

    public var id: String { bundleIdentifier ?? path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var historyKey: String { path }

    public init(name: String, bundleIdentifier: String?, url: URL, alternateNames: [String] = []) {
        self.name = name
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
    public func matchRank(for query: String) -> Int? {
        (searchIndexes.compactMap { $0.matchRank(for: query) } +
            [SearchTextIndex.identifierRank(bundleIdentifier, for: query)].compactMap { $0 }).min()
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
        var indexedApplications: [String: SystemApplicationDescriptor] = [:]
        for root in roots {
            for application in applications(in: root, fileManager: fileManager) {
                // roots 的顺序定义重复 Bundle ID 的优先级：用户、全局、系统。
                let key = application.bundleIdentifier ?? application.path
                if indexedApplications[key] == nil {
                    indexedApplications[key] = application
                }
            }
        }
        return indexedApplications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func applications(in root: URL, fileManager: FileManager) -> [SystemApplicationDescriptor] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        if root.pathExtension == "app" {
            return descriptor(for: root, fileManager: fileManager).map { [$0] } ?? []
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [SystemApplicationDescriptor] = []
        for case let sourceURL as URL in enumerator {
            let url = resolvedApplicationURL(for: sourceURL)
            guard url.pathExtension == "app" else { continue }
            enumerator.skipDescendants()
            guard let descriptor = descriptor(for: url, fileManager: fileManager) else { continue }
            result.append(descriptor)
        }
        return result
    }

    private func resolvedApplicationURL(for url: URL) -> URL {
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true else { return url }
        return (try? URL(resolvingAliasFileAt: url, options: [])) ?? url
    }

    private func descriptor(for url: URL, fileManager: FileManager) -> SystemApplicationDescriptor? {
        guard !url.lastPathComponent.hasPrefix("."),
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary,
              info["CFBundlePackageType"] as? String == "APPL",
              (info["LSBackgroundOnly"] as? Bool) != true,
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path)
        else {
            return nil
        }

        let localizedNames = localizedNames(in: bundle)
        // 不调用 localizedInfoDictionary：损坏的 loctable 可能触发无法用 Swift catch 捕获的系统异常。
        let localizedInfo = localizedNames.isEmpty
            ? propertyListDictionary(at: bundle.url(forResource: "InfoPlist", withExtension: "strings")) : [:]
        let name = localizedNames.first
            ?? (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let alternateNames = [
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String
        ].compactMap { $0 } + localizedNames
        return SystemApplicationDescriptor(
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            url: url,
            alternateNames: alternateNames
        )
    }

    private func localizedNames(in bundle: Bundle) -> [String] {
        // 系统应用可能只在 loctable 中保存名称；每次扫描只解析一次，共享给各语言。
        let table = propertyListDictionary(at: bundle.url(forResource: "InfoPlist", withExtension: "loctable"))
        let tableLocalizations = table.keys.filter {
            $0 != "LocProvenance" && $0 != "NonLocalized" && table[$0] is [String: Any]
        }
        let availableLocalizations = Set(bundle.localizations + tableLocalizations).sorted()
        let preferredLocalizations = Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: preferredLanguages
        )
        let localizations = preferredLocalizations + availableLocalizations.filter {
            !preferredLocalizations.contains($0)
        }
        return localizations.flatMap { localization -> [String] in
            let strings = propertyListDictionary(at: bundle.url(
                forResource: "InfoPlist",
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            ))
            let localizedTable = table[localization] as? [String: Any] ?? [:]

            // 首选语言先显示，同语言沿用 strings 的优先级；其余名称作为搜索别名。
            return [strings, localizedTable].flatMap { info in
                [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String]
                    .compactMap { $0 }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }
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
    private static let version = 5

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
