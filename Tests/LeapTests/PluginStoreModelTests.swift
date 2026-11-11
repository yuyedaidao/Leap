import Foundation
import Testing

@testable import LeapCore

@MainActor
struct PluginStoreModelTests {
    private let indexURL = "https://raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json"

    private func index(version: String) -> Data {
        Data(
            """
            {"schemaVersion": 1, "plugins": [
              {"id": "com.padding.leap.json-formatter", "name": "JSON 格式化", "version": "\(version)",
               "summary": "粘贴 JSON 自动格式化", "path": "plugins/json-formatter", "commands": ["JSON 格式化"]}
            ]}
            """.utf8)
    }

    private func makePaths() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapStoreUI-\(UUID().uuidString)")
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupportDirectory: support, resourceDirectory: support)
        return (paths, root)
    }

    private func writeCache(_ paths: AppPaths, version: String) throws {
        try FileManager.default.createDirectory(
            at: paths.pluginStoreCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try index(version: version).write(to: paths.pluginStoreCacheURL)
    }

    @Test("先展示缓存，再用网络结果覆盖")
    func loadsCacheThenRefreshes() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(paths, version: "1.0.0")
        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: index(version: "1.1.0"))])
        let model = PluginStoreModel(
            paths: paths,
            catalog: PluginStoreCatalog(client: mock, cacheURL: paths.pluginStoreCacheURL)
        )

        #expect(model.entries.isEmpty)
        await model.loadIfNeeded()
        #expect(model.entries.map(\.version) == ["1.1.0"])
        #expect(!model.isShowingCachedResult)
        #expect(model.errorMessage == nil)
    }

    @Test("刷新失败时保留缓存并标注上次结果")
    func keepsCacheOnFailure() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(paths, version: "1.0.0")
        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: Data(), status: 500)])
        let model = PluginStoreModel(
            paths: paths,
            catalog: PluginStoreCatalog(client: mock, cacheURL: paths.pluginStoreCacheURL)
        )

        await model.loadIfNeeded()
        #expect(model.entries.map(\.version) == ["1.0.0"])
        #expect(model.isShowingCachedResult)
        #expect(model.errorMessage?.contains("上次结果") == true)
    }

    @Test("允许刷新关闭时只读缓存，不联网")
    func offlineUsesCacheOnly() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(paths, version: "1.0.0")
        let mock = GitHubFixtureClient(replies: [:])
        let model = PluginStoreModel(
            paths: paths,
            catalog: PluginStoreCatalog(client: mock, cacheURL: paths.pluginStoreCacheURL),
            allowsRefresh: false
        )

        await model.loadIfNeeded()
        #expect(model.entries.map(\.version) == ["1.0.0"])
        #expect(await mock.requests.isEmpty)
    }

    @Test("没有缓存且刷新失败时展示错误，条目为空")
    func failureWithoutCache() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: Data(), status: 404)])
        let model = PluginStoreModel(
            paths: paths,
            catalog: PluginStoreCatalog(client: mock, cacheURL: paths.pluginStoreCacheURL)
        )

        await model.loadIfNeeded()
        #expect(model.entries.isEmpty)
        #expect(!model.isShowingCachedResult)
        #expect(model.errorMessage != nil)
    }

    @Test("搜索匹配名称、简介、命令与 ID，大小写与空格不敏感")
    func query() throws {
        let entry = PluginStoreEntry(
            id: "com.padding.leap.json-formatter", name: "JSON 格式化", version: "1.0.0",
            summary: "粘贴 JSON 自动格式化", path: "plugins/json-formatter", commands: ["JSON 格式化"])
        #expect(PluginStoreQuery(searchText: "  ").includes(entry))
        #expect(PluginStoreQuery(searchText: "格式化").includes(entry))
        #expect(PluginStoreQuery(searchText: "粘贴").includes(entry))
        #expect(PluginStoreQuery(searchText: "formatter").includes(entry))
        #expect(!PluginStoreQuery(searchText: "关机").includes(entry))
    }
}
