import Foundation
@preconcurrency import YQLogger

public struct RemotePluginProgress: Sendable {
    public enum Phase: Sendable { case resolving, downloading }
    public let phase: Phase
    public let completedFiles: Int
    public let totalFiles: Int
    public let downloadedBytes: Int
}

public struct RemotePluginDownload: Sendable {
    private static let logger = YQLogger(label: "com.padding.leap/remote-plugin-cleanup")
    public let directory: URL
    public let source: RemotePluginSource

    public func remove() {
        do { try FileManager.default.removeItem(at: directory) } catch {
            Self.logger.warning("无法清理插件临时目录：\(error.localizedDescription)。")
        }
    }
}

public struct RemotePluginDownloader: Sendable {
    static let maximumFiles = 5_000
    static let maximumFileBytes = 20 * 1_024 * 1_024
    static let maximumTotalBytes = 100 * 1_024 * 1_024
    static let maximumDepth = 32
    private static let maximumMetadataBytes = 4 * 1_024 * 1_024
    private static let logger = YQLogger(label: "com.padding.leap/remote-plugin")

    private let client: any RemotePluginHTTPClient
    private let temporaryDirectory: URL

    public init(
        client: any RemotePluginHTTPClient = GitHubPluginHTTPClient(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.client = client
        self.temporaryDirectory = temporaryDirectory
    }

    public func download(
        address: String,
        progress: @escaping @Sendable (RemotePluginProgress) async -> Void = { _ in }
    ) async throws -> RemotePluginDownload {
        do {
            return try await prepare(address: address, progress: progress)
        } catch {
            if !Task.isCancelled {
                Self.logger.error("远程插件准备失败：\(error.localizedDescription)。")
            }
            throw error
        }
    }

    private func prepare(
        address: String,
        progress: @escaping @Sendable (RemotePluginProgress) async -> Void
    ) async throws -> RemotePluginDownload {
        let address = try GitHubPluginAddress(address)
        await progress(.init(phase: .resolving, completedFiles: 0, totalFiles: 0, downloadedBytes: 0))
        Self.logger.info("开始解析远程插件目录。")
        let (commit, path) = try await resolve(address)
        let files = try await enumerate(address: address, root: commit.commit.tree.sha, path: path)
        let directory = temporaryDirectory.appendingPathComponent("LeapRemote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepDirectory = false
        defer { if !keepDirectory { try? FileManager.default.removeItem(at: directory) } }
        await progress(.init(phase: .downloading, completedFiles: 0, totalFiles: files.count, downloadedBytes: 0))

        // 有界任务组：失败或取消会先等待子任务退出，再清理共同临时目录。
        try await withThrowingTaskGroup(of: Int.self) { group in
            var iterator = files.makeIterator()
            func enqueue(_ file: Tree.Entry) {
                group.addTask {
                    try await downloadFile(file, address: address, commit: commit.sha, path: path, directory: directory)
                }
            }
            for _ in 0..<min(4, files.count) {
                if let file = iterator.next() { enqueue(file) }
            }
            var completed = 0
            var downloaded = 0
            while let size = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                downloaded += size
                guard downloaded <= Self.maximumTotalBytes else { throw RemotePluginError.limitExceeded("总大小 100 MiB") }
                await progress(
                    .init(
                        phase: .downloading, completedFiles: completed, totalFiles: files.count,
                        downloadedBytes: downloaded
                    ))
                if let file = iterator.next() { enqueue(file) }
            }
        }
        try Task.checkCancellation()
        let source = RemotePluginSource(
            directoryURL: address.url, owner: address.owner, repository: address.repository,
            path: path.joined(separator: "/"), commit: commit.sha
        )
        Self.logger.info("目标插件文件准备完成：\(files.count) 个文件。")
        keepDirectory = true
        return RemotePluginDownload(directory: directory, source: source)
    }

    private struct Commit: Decodable {
        let sha: String
        let commit: Details
        struct Details: Decodable {
            let tree: Identifier
        }
        struct Identifier: Decodable { let sha: String }
    }

    private struct Tree: Decodable {
        let tree: [Entry]
        let truncated: Bool
        struct Entry: Decodable, Sendable {
            let path: String
            let mode: String
            let type: String
            let sha: String
            let size: Int?
        }
    }

    private func resolve(_ address: GitHubPluginAddress) async throws -> (Commit, [String]) {
        // 最长真实引用优先，避免把含 / 的分支名称误当成插件目录。
        for length in stride(from: address.referenceAndPath.count - 1, through: 1, by: -1) {
            try Task.checkCancellation()
            let reference = address.referenceAndPath.prefix(length).joined(separator: "/")
            let url = try apiURL(address, components: ["commits", reference])
            do {
                let commit: Commit = try await metadata(url, resolvingReference: true)
                guard Self.isObjectID(commit.sha), Self.isObjectID(commit.commit.tree.sha) else {
                    throw RemotePluginError.incompleteDownload
                }
                return (commit, Array(address.referenceAndPath.dropFirst(length)))
            } catch RemotePluginError.notFound {
                continue
            }
        }
        throw RemotePluginError.notFound
    }

    private func enumerate(address: GitHubPluginAddress, root: String, path: [String]) async throws -> [Tree.Entry] {
        var treeID = root
        for component in path {
            let tree: Tree = try await metadata(apiURL(address, components: ["git", "trees", treeID]))
            guard !tree.truncated else { throw RemotePluginError.incompleteDownload }
            let matches = tree.tree.filter { $0.path == component }
            guard matches.count == 1, let entry = matches.first,
                entry.type == "tree", entry.mode == "040000", Self.isObjectID(entry.sha)
            else {
                throw RemotePluginError.notFound
            }
            treeID = entry.sha
        }
        let tree: Tree = try await metadata(apiURL(address, components: ["git", "trees", treeID], recursive: true))
        guard !tree.truncated else { throw RemotePluginError.incompleteDownload }
        var known: [String: String] = [:]
        var files: [Tree.Entry] = []
        var totalBytes = 0
        for entry in tree.tree {
            let components = try Self.safeComponents(entry.path)
            guard components.count <= Self.maximumDepth else { throw RemotePluginError.limitExceeded("目录深度 32") }
            // 预检 Unicode 与大小写冲突；写入时仍用独占创建防止文件系统别名覆盖。
            for depth in 1...components.count {
                let prefix = components.prefix(depth).joined(separator: "/")
                let key = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = known[key], previous != prefix { throw RemotePluginError.unsafePath }
                known[key] = prefix
            }
            guard Self.isObjectID(entry.sha) else { throw RemotePluginError.incompleteDownload }
            if entry.type == "tree", entry.mode == "040000" { continue }
            guard entry.type == "blob", ["100644", "100755"].contains(entry.mode) else {
                throw RemotePluginError.unsupportedFile
            }
            guard let size = entry.size, size >= 0 else { throw RemotePluginError.incompleteDownload }
            guard size <= Self.maximumFileBytes else { throw RemotePluginError.limitExceeded("单文件 20 MiB") }
            totalBytes += size
            guard totalBytes <= Self.maximumTotalBytes else { throw RemotePluginError.limitExceeded("总大小 100 MiB") }
            files.append(entry)
            guard files.count <= Self.maximumFiles else { throw RemotePluginError.limitExceeded("文件数 5,000") }
        }
        guard !files.isEmpty, Set(tree.tree.map(\.path)).count == tree.tree.count else {
            throw RemotePluginError.incompleteDownload
        }
        let filePaths = Set(files.map(\.path))
        for file in files {
            let components = try Self.safeComponents(file.path)
            for length in 1..<components.count
            where filePaths.contains(components.prefix(length).joined(separator: "/")) {
                throw RemotePluginError.unsafePath
            }
        }
        return files
    }

    private func downloadFile(
        _ file: Tree.Entry, address: GitHubPluginAddress, commit: String, path: [String], directory: URL
    ) async throws -> Int {
        try Task.checkCancellation()
        let url = try Self.url(
            host: "raw.githubusercontent.com",
            components: [address.owner, address.repository, commit] + path + Self.safeComponents(file.path))
        let response = try await client.download(url, maximumBytes: file.size ?? 0)
        defer { try? FileManager.default.removeItem(at: response.file) }
        try Self.validate(response)
        let values = try response.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == file.size else {
            throw RemotePluginError.incompleteDownload
        }
        let handle = try FileHandle(forReadingFrom: response.file)
        defer { try? handle.close() }
        if let prefix = try handle.read(upToCount: 128),
            prefix.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8))
        {
            throw RemotePluginError.unsupportedFile
        }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // copyItem 不覆盖已存在的目标，也能检测 APFS 的名称归一化冲突。
        try FileManager.default.copyItem(at: response.file, to: destination)
        if file.mode == "100755" {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        return values.fileSize ?? 0
    }

    private func metadata<T: Decodable>(_ url: URL, resolvingReference: Bool = false) async throws -> T {
        try Task.checkCancellation()
        let response = try await client.download(url, maximumBytes: Self.maximumMetadataBytes)
        defer { try? FileManager.default.removeItem(at: response.file) }
        let data = try Data(contentsOf: response.file)
        guard data.count <= Self.maximumMetadataBytes else { throw RemotePluginError.limitExceeded("目录元数据") }
        if resolvingReference, response.status == 422,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String, message.hasPrefix("No commit found for SHA:")
        {
            throw RemotePluginError.notFound
        }
        try Self.validate(response)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw RemotePluginError.incompleteDownload }
    }

    static func validate(_ response: RemotePluginHTTPResponse) throws {
        if response.status == 403 || response.status == 429 {
            if response.status == 429 || response.headers["x-ratelimit-remaining"] == "0"
                || response.headers["retry-after"] != nil
            {
                let reset = response.headers["x-ratelimit-reset"].flatMap(Double.init).map {
                    Date(timeIntervalSince1970: $0).formatted(date: .numeric, time: .standard)
                }
                throw RemotePluginError.rateLimited(reset)
            }
        }
        guard response.status != 404 else { throw RemotePluginError.notFound }
        guard response.status == 200 else { throw RemotePluginError.httpStatus(response.status) }
    }

    static func safeComponents(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            })
        else { throw RemotePluginError.unsafePath }
        return components
    }

    private static func isObjectID(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func apiURL(_ address: GitHubPluginAddress, components: [String], recursive: Bool = false) throws -> URL {
        try Self.url(
            host: "api.github.com", components: ["repos", address.owner, address.repository] + components,
            recursive: recursive)
    }

    private static func url(host: String, components: [String], recursive: Bool = false) throws -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        url.percentEncodedPath =
            "/"
            + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        if recursive { url.queryItems = [.init(name: "recursive", value: "1")] }
        guard let result = url.url else { throw RemotePluginError.invalidAddress }
        return result
    }
}
