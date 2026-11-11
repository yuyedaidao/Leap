import Foundation
@preconcurrency import YQLogger

public struct PluginStoreSnapshot: Equatable, Sendable {
    public let index: PluginStoreIndex
    /// 缓存时间用于提示结果的新旧；实时刷新时为本机当前时间。
    public let updatedAt: Date

    public init(index: PluginStoreIndex, updatedAt: Date) {
        self.index = index
        self.updatedAt = updatedAt
    }
}

/// 只负责获取与缓存索引，界面状态由 `PluginStoreModel` 协调。
public struct PluginStoreCatalog: Sendable {
    private static let logger = YQLogger(label: "com.padding.leap/plugin-store")

    private let client: any RemotePluginHTTPClient
    private let source: PluginStoreSource
    private let cacheURL: URL

    public init(
        client: any RemotePluginHTTPClient = GitHubPluginHTTPClient(),
        source: PluginStoreSource = .official,
        cacheURL: URL
    ) {
        self.client = client
        self.source = source
        self.cacheURL = cacheURL
    }

    /// 缓存不可用（缺失、损坏、旧版本）时返回 nil，由调用方决定是否提示离线。
    public func cached() -> PluginStoreSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL), let index = try? PluginStoreIndex.decode(data) else {
            return nil
        }
        let date = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return PluginStoreSnapshot(index: index, updatedAt: date ?? .distantPast)
    }

    public func refresh() async throws -> PluginStoreSnapshot {
        let response = try await client.download(source.indexURL, maximumBytes: PluginStoreIndex.maximumIndexBytes)
        defer { try? FileManager.default.removeItem(at: response.file) }
        // 索引 404 与应用商店语义无关，换成商店自己的提示，避免误以为是插件目录地址有问题。
        do { try RemotePluginDownloader.validate(response) } catch RemotePluginError.notFound {
            throw PluginStoreError.notFound
        }
        let data = try Data(contentsOf: response.file)
        let index = try PluginStoreIndex.decode(data)
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // 缓存写失败不影响本次展示，只是下次打开需要重新联网。
            Self.logger.warning("无法写入插件商店缓存：\(error.localizedDescription)。")
        }
        Self.logger.info("插件商店索引已更新：\(index.plugins.count) 个插件。")
        return PluginStoreSnapshot(index: index, updatedAt: Date())
    }
}
