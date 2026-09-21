import Foundation

public struct SystemApplicationDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String
    public let normalizedName: String
    public let pinyin: String
    public let pinyinInitials: String

    public var id: String { bundleIdentifier ?? path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var historyKey: String { path }

    public init(name: String, bundleIdentifier: String?, url: URL) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        path = url.standardizedFileURL.resolvingSymlinksInPath().path
        normalizedName = Self.normalize(name)
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        pinyin = Self.normalize(latin)
        pinyinInitials = latin
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// 数值越小表示文本匹配越直接，调用方再以使用记录解决同级排序。
    public func matchRank(for query: String) -> Int? {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return nil }
        let bundleID = Self.normalize(bundleIdentifier ?? "")

        if normalizedName == query { return 0 }
        if normalizedName.hasPrefix(query) { return 1 }
        if normalizedName.contains(query) { return 2 }
        if bundleID.hasPrefix(query) { return 3 }
        if bundleID.contains(query) { return 4 }
        if pinyin == query { return 5 }
        if pinyin.hasPrefix(query) { return 6 }
        if pinyin.contains(query) { return 7 }
        if pinyinInitials.hasPrefix(query) { return 8 }
        return nil
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

public struct SystemApplicationScanner: Sendable {
    public static let defaultRoots = [
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
    ]

    public let roots: [URL]

    public init(roots: [URL] = Self.defaultRoots) {
        self.roots = roots.map(\.standardizedFileURL)
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

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return SystemApplicationDescriptor(name: name, bundleIdentifier: bundle.bundleIdentifier, url: url)
    }
}

public enum SystemApplicationIndexCache {
    private struct Snapshot: Codable {
        let version: Int
        let applications: [SystemApplicationDescriptor]
    }

    private static let version = 1

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
