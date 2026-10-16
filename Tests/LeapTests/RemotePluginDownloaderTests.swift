import Foundation
import Testing

@testable import LeapCore

struct RemotePluginDownloaderTests {
    @Test("目录地址规范化，包括编码路径和尾斜杠")
    func address() throws {
        let parsed = try GitHubPluginAddress(" https://github.com/o/r/tree/main/plugins/%E4%BD%A0%E5%A5%BD/ ")
        #expect(parsed.owner == "o")
        #expect(parsed.repository == "r")
        #expect(parsed.referenceAndPath == ["main", "plugins", "你好"])
    }

    @Test(
        "非法地址在联网前拒绝",
        arguments: [
            "http://github.com/o/r/tree/main/a", "https://github.com/o/r", "https://github.com/o/r/tree/main",
            "https://github.com/o/r/blob/main/a", "https://user:pass@github.com/o/r/tree/main/a",
            "https://github.com/o/r/tree/main/%2e%2e/a", "https://github.com/o/r/tree/main/a%2fb",
            "https://github.com/o/r/tree/main/a//b", "https://github.com/o/r/tree/main/a?token=secret",
            "https://example.com/o/r/tree/main/a", "https://github.com:443/o/r/tree/main/a",
        ])
    func invalidAddress(_ input: String) {
        #expect(throws: RemotePluginError.invalidAddress) { try GitHubPluginAddress(input) }
    }

    @Test("只下载目标子树，保留隐藏文件和依赖，所有正文固定提交")
    func targetOnly() async throws {
        let files = [
            "main.js": Data("hello".utf8), ".config": Data("hidden".utf8), "lib/dependency.js": Data("dependency".utf8),
        ]
        let mock = GitHubFixtureClient(replies: try Self.fixtures(files: files))
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await RemotePluginDownloader(client: mock, temporaryDirectory: root)
            .download(address: "https://github.com/o/r/tree/main/plugins/a")
        #expect(result.source.commit == Self.commit)
        for (path, data) in files {
            #expect(try Data(contentsOf: result.directory.appendingPathComponent(path)) == data)
        }
        let requests = await mock.requests
        let raw = requests.filter { $0.host == "raw.githubusercontent.com" }
        #expect(raw.count == files.count)
        #expect(raw.allSatisfy { $0.path.contains("/\(Self.commit)/plugins/a/") })
        #expect(
            !requests.contains {
                $0.absoluteString.contains("archive") || $0.path.contains("plugins/b/")
                    || $0.path.contains(Self.sibling)
            })
        #expect(await mock.maximumActive <= 4)
        result.remove()
        #expect(!FileManager.default.fileExists(atPath: result.directory.path))
    }

    @Test("带斜杠的分支和标签采用最长真实引用", arguments: ["feature/work", "release/v1"])
    func slashReference(_ reference: String) async throws {
        let mock = GitHubFixtureClient(replies: try Self.fixtures(files: ["main.js": Data()], reference: reference))
        let result = try await RemotePluginDownloader(client: mock)
            .download(address: "https://github.com/o/r/tree/\(reference)/plugins/a")
        defer { result.remove() }
        #expect(result.source.path == "plugins/a")
        #expect(result.source.commit == Self.commit)
    }

    @Test(
        "不完整、越界和特殊条目均拒绝",
        arguments: [
            "../escape", "/escape", "nested/../../escape", "bad\\path", "link", "module", "duplicate", "case",
            "unicode", "prefix", "truncated", "size", "depth", "count", "total",
        ])
    func invalidTree(_ kind: String) async throws {
        var entries = [Self.entry("main.js", size: 0)]
        switch kind {
        case "link": entries = [Self.entry("link", mode: "120000", size: 0)]
        case "module": entries = [Self.entry("module", mode: "160000", type: "commit", size: 0)]
        case "duplicate": entries += entries
        case "case": entries += [Self.entry("Main.js", size: 0)]
        case "unicode": entries = [Self.entry("é", size: 0), Self.entry("e\u{301}", size: 0)]
        case "prefix": entries = [Self.entry("lib", size: 0), Self.entry("lib/file", size: 0)]
        case "size": entries = [Self.entry("large", size: RemotePluginDownloader.maximumFileBytes + 1)]
        case "depth": entries = [Self.entry(Array(repeating: "a", count: 33).joined(separator: "/"), size: 0)]
        case "count": entries = (0...RemotePluginDownloader.maximumFiles).map { Self.entry("file\($0)", size: 0) }
        case "total": entries = (0..<6).map { Self.entry("file\($0)", size: RemotePluginDownloader.maximumFileBytes) }
        case "truncated": break
        default: entries = [Self.entry(kind, size: 0)]
        }
        var fixtures = try Self.fixtures(files: [:])
        fixtures[Self.targetURL] = try .json(["tree": entries, "truncated": kind == "truncated"])
        let mock = GitHubFixtureClient(replies: fixtures)
        await #expect(throws: (any Error).self) {
            try await RemotePluginDownloader(client: mock).download(
                address: "https://github.com/o/r/tree/main/plugins/a")
        }
        #expect(!(await mock.requests).contains { $0.host == "raw.githubusercontent.com" })
    }

    @Test("下载失败、大小不符和LFS指针均清理临时目录", arguments: ["missing", "size", "lfs", "cancel"])
    func cleanup(_ kind: String) async throws {
        var fixtures = try Self.fixtures(files: ["main.js": Data("hello".utf8)])
        let rawURL = "https://raw.githubusercontent.com/o/r/\(Self.commit)/plugins/a/main.js"
        switch kind {
        case "missing": fixtures[rawURL] = .init(data: Data(), status: 404)
        case "size": fixtures[rawURL] = .init(data: Data())
        case "lfs":
            fixtures = try Self.fixtures(files: [
                "main.js": Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc".utf8)
            ])
        default: break
        }
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = GitHubFixtureClient(replies: fixtures, delay: kind == "cancel" ? .seconds(10) : .milliseconds(1))
        let task = Task {
            try await RemotePluginDownloader(client: mock, temporaryDirectory: root)
                .download(address: "https://github.com/o/r/tree/main/plugins/a")
        }
        if kind == "cancel" {
            while !(await mock.requests).contains(where: { $0.host == "raw.githubusercontent.com" }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            task.cancel()
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] == [])
    }

    @Test("限流提供恢复时间，未知HTTP状态和危险下载主机拒绝")
    func networkErrors() throws {
        #expect(throws: RemotePluginError.rateLimited(nil)) {
            try RemotePluginDownloader.validate(.init(file: Self.root(), status: 429))
        }
        do {
            try RemotePluginDownloader.validate(
                .init(
                    file: Self.root(), status: 403,
                    headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "2000000000"]))
            Issue.record("应返回限流错误")
        } catch RemotePluginError.rateLimited(let reset) { #expect(reset != nil) }
        #expect(throws: RemotePluginError.httpStatus(500)) {
            try RemotePluginDownloader.validate(.init(file: Self.root(), status: 500))
        }
        #expect(!GitHubPluginHTTPClient.isAllowed(URL(string: "https://example.com/file")!))
        #expect(!GitHubPluginHTTPClient.isAllowed(URL(string: "http://raw.githubusercontent.com/file")!))
        #expect(GitHubPluginHTTPClient.isAllowed(URL(string: "https://raw.githubusercontent.com/o/r/file")!))
    }

    @Test("重定向代理拒绝越界主机并取消请求")
    func redirectGuard() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/o/r"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let redirect = GitHubRedirectGuard()
        var completed = false
        redirect.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.com/payload")!)
        ) { request in
            #expect(request == nil)
            completed = true
        }
        #expect(completed)
        #expect(redirect.didReject)
    }

    static let commit = String(repeating: "a", count: 40)
    static let rootTree = String(repeating: "b", count: 40)
    static let plugins = String(repeating: "c", count: 40)
    static let target = String(repeating: "d", count: 40)
    static let sibling = String(repeating: "e", count: 40)
    static let targetURL = "https://api.github.com/repos/o/r/git/trees/\(target)?recursive=1"

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RemoteTests-\(UUID().uuidString)")
    }

    static func entry(
        _ path: String, mode: String = "100644", type: String = "blob", size: Int = 0, sha: String = commit
    ) -> [String: Any] {
        ["path": path, "mode": mode, "type": type, "size": size, "sha": sha]
    }

    static func fixtures(files: [String: Data], reference: String = "main") throws -> [String: GitHubFixtureClient
        .Reply]
    {
        var result: [String: GitHubFixtureClient.Reply] = try [
            "https://api.github.com/repos/o/r/commits/\(reference)": .json([
                "sha": commit, "commit": ["tree": ["sha": rootTree]],
            ]),
            "https://api.github.com/repos/o/r/git/trees/\(rootTree)": .json([
                "tree": [entry("plugins", mode: "040000", type: "tree", sha: plugins)], "truncated": false,
            ]),
            "https://api.github.com/repos/o/r/git/trees/\(plugins)": .json([
                "tree": [
                    entry("a", mode: "040000", type: "tree", sha: target),
                    entry("b", mode: "040000", type: "tree", sha: sibling),
                ],
                "truncated": false,
            ]),
            targetURL: .json(["tree": files.map { entry($0.key, size: $0.value.count) }, "truncated": false]),
        ]
        for (path, data) in files {
            result["https://raw.githubusercontent.com/o/r/\(commit)/plugins/a/\(path)"] = .init(data: data)
        }
        return result
    }
}

actor GitHubFixtureClient: RemotePluginHTTPClient {
    struct Reply: Sendable {
        let data: Data
        var status = 200

        static func json(_ object: [String: Any]) throws -> Self {
            Self(data: try JSONSerialization.data(withJSONObject: object))
        }
    }

    let replies: [String: Reply]
    let delay: Duration
    private(set) var requests: [URL] = []
    private(set) var maximumActive = 0
    private var active = 0

    init(replies: [String: Reply], delay: Duration = .milliseconds(1)) {
        self.replies = replies
        self.delay = delay
    }

    func download(_ url: URL, maximumBytes: Int) async throws -> RemotePluginHTTPResponse {
        requests.append(url)
        if url.host == "raw.githubusercontent.com" {
            active += 1
            defer { active -= 1 }
            maximumActive = max(maximumActive, active)
            try await Task.sleep(for: delay)
        }
        let fallback =
            url.path.contains("/commits/")
            ? Reply(data: Data("{\"message\":\"No commit found for SHA: missing\"}".utf8), status: 422)
            : Reply(data: Data(), status: 404)
        let reply = replies[url.absoluteString.removingPercentEncoding ?? ""] ?? fallback
        let file = RemotePluginDownloaderTests.root()
        try reply.data.write(to: file)
        return .init(file: file, status: reply.status)
    }
}
