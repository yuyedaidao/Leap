import Foundation
import LeapCore
import Observation
import YQLogger

/// 只在设置页存在期间持有商店索引状态；安装流程仍由 `PluginInstallationModel` 负责。
@MainActor
@Observable
final class PluginStoreModel {
    private static let logger = YQLogger(label: "com.padding.leap/plugin-store-ui")

    private let catalog: PluginStoreCatalog
    /// UI 测试与离线场景跳过联网刷新，只展示缓存。
    private let allowsRefresh: Bool
    private var hasLoaded = false

    private(set) var index: PluginStoreIndex?
    private(set) var updatedAt: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 有缓存但刷新失败时为真，用于标注当前结果来自上次。
    private(set) var isShowingCachedResult = false

    init(paths: AppPaths, catalog: PluginStoreCatalog? = nil, allowsRefresh: Bool = true) {
        self.catalog = catalog ?? PluginStoreCatalog(cacheURL: paths.pluginStoreCacheURL)
        self.allowsRefresh = allowsRefresh
    }

    var entries: [PluginStoreEntry] { index?.plugins ?? [] }

    func entry(id: String) -> PluginStoreEntry? {
        index?.entry(id: id)
    }

    /// 先展示缓存再刷新，避免商店页出现空白等待。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        if let snapshot = catalog.cached() {
            index = snapshot.index
            updatedAt = snapshot.updatedAt
        }
        await refresh()
    }

    func refresh() async {
        guard allowsRefresh, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await catalog.refresh()
            index = snapshot.index
            updatedAt = snapshot.updatedAt
            errorMessage = nil
            isShowingCachedResult = false
        } catch {
            Self.logger.error("插件商店索引刷新失败：\(error.localizedDescription)。")
            isShowingCachedResult = index != nil
            errorMessage = isShowingCachedResult
                ? "无法更新插件商店，正在显示上次结果：\(error.localizedDescription)"
                : error.localizedDescription
        }
    }
}
