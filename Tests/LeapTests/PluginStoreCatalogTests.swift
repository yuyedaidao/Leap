import Foundation
import Testing

@testable import LeapCore

struct PluginStoreCatalogTests {
    private let indexURL = "https://raw.githubusercontent.com/yuyedaidao/LeapPlugins/main/store.json"

    private var indexData: Data {
        Data(
            """
            {"schemaVersion": 1, "name": "Leap 官方插件", "plugins": [
              {"id": "com.padding.leap.json-formatter", "name": "JSON 格式化", "version": "1.0.0",
               "summary": "粘贴 JSON 自动格式化", "path": "plugins/json-formatter", "runtime": "javascript"}
            ]}
            """.utf8)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("刷新成功后写入缓存，下次可离线读回")
    func refreshWritesCache() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("PluginStore/store.json")
        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: indexData)])
        let catalog = PluginStoreCatalog(client: mock, cacheURL: cacheURL)

        #expect(catalog.cached() == nil)
        let snapshot = try await catalog.refresh()
        #expect(snapshot.index.plugins.map(\.id) == ["com.padding.leap.json-formatter"])
        #expect(abs(snapshot.updatedAt.timeIntervalSinceNow) < 5)
        #expect(await mock.requests.map(\.absoluteString) == [indexURL])

        let cached = try #require(catalog.cached())
        #expect(cached.index == snapshot.index)
    }

    @Test("刷新失败时保留上一次缓存")
    func refreshKeepsCacheOnFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("PluginStore/store.json")
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try indexData.write(to: cacheURL)

        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: Data(), status: 500)])
        let catalog = PluginStoreCatalog(client: mock, cacheURL: cacheURL)
        await #expect(throws: RemotePluginError.httpStatus(500)) { try await catalog.refresh() }
        #expect(catalog.cached()?.index.plugins.count == 1)
    }

    @Test("索引内容损坏时缓存不被覆盖")
    func refreshRejectsMalformedIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("PluginStore/store.json")
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try indexData.write(to: cacheURL)

        let mock = GitHubFixtureClient(replies: [indexURL: .init(data: Data("oops".utf8))])
        let catalog = PluginStoreCatalog(client: mock, cacheURL: cacheURL)
        await #expect(throws: PluginStoreError.invalidIndex) { try await catalog.refresh() }
        #expect(catalog.cached()?.index.plugins.count == 1)
    }

    @Test("限流错误带恢复时间")
    func rateLimited() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = GitHubFixtureClient(
            replies: [
                indexURL: .init(
                    data: Data(), status: 403,
                    headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000"])
            ])
        let catalog = PluginStoreCatalog(client: mock, cacheURL: root.appendingPathComponent("store.json"))
        do {
            _ = try await catalog.refresh()
            Issue.record("限流应当抛错")
        } catch let error as RemotePluginError {
            guard case .rateLimited(let reset) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reset != nil)
        }
    }

    @Test("损坏的缓存视为没有缓存")
    func damagedCache() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("store.json")
        try Data("{".utf8).write(to: cacheURL)
        #expect(PluginStoreCatalog(client: GitHubFixtureClient(replies: [:]), cacheURL: cacheURL).cached() == nil)
    }
}
