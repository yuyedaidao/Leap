import LeapCore
import SwiftUI

struct PluginStorePage: View {
    let installation: PluginInstallationModel
    let store: PluginStoreModel
    @Binding var route: PluginSettingsRoute

    @State private var query = PluginStoreQuery()

    private var installedPlugins: [String: InstalledPluginDescriptor] {
        Dictionary(installation.plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var visibleEntries: [PluginStoreEntry] {
        store.entries.filter(query.includes)
    }

    private var isBusy: Bool { installation.isPreparing || installation.isInstalling }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            list
            if let error = installation.errorMessage {
                SettingsErrorMessage(error)
            }
            if let error = store.errorMessage {
                SettingsErrorMessage(error)
                    .accessibilityIdentifier("settings.pluginStoreError")
            }
        }
        .padding(24)
        .safeAreaInset(edge: .bottom, spacing: 0) { updatedAtBar }
        .searchable(text: $query.searchText, placement: .toolbar, prompt: "搜索商店插件")
        .toolbar {
            ToolbarItem(id: "plugin-store-refresh", placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .labelStyle(.iconOnly)
                    .disabled(store.isLoading)
                    .help("重新获取插件商店索引")
                    .accessibilityIdentifier("settings.pluginStoreRefresh")
            }
        }
        .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private var list: some View {
        if visibleEntries.isEmpty {
            ContentUnavailableView(
                query.term.isEmpty ? "插件商店暂无可安装插件" : "没有匹配的插件",
                systemImage: query.term.isEmpty ? "storefront" : "magnifyingglass",
                description: Text(query.term.isEmpty ? "检查网络后点刷新重试。" : "尝试其他关键词。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("settings.pluginStoreEmptyState")
        } else {
            List {
                Section {
                    ForEach(visibleEntries) { entry in
                        PluginStoreRow(
                            entry: entry,
                            state: entry.state(installedVersion: installedPlugins[entry.id]?.manifest.version),
                            installed: installedPlugins[entry.id],
                            isBusy: isBusy,
                            requestDetails: { open(entry) },
                            requestInstall: { install(entry) }
                        )
                    }
                } header: {
                    Text("\(store.index?.name ?? "官方插件") · \(visibleEntries.count)")
                        .accessibilityIdentifier("settings.pluginStoreGroup")
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("settings.pluginStoreList")
        }
    }

    /// 索引更新于固定在底部状态条，避免随列表滚走或被当成普通行。
    private var updatedAtBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(updatedAtText)
                    .accessibilityIdentifier("settings.pluginStoreUpdatedAt")
                Spacer()
                if store.isShowingCachedResult {
                    Text("显示上次结果")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var updatedAtText: String {
        guard let updatedAt = store.updatedAt else { return "尚未获取索引" }
        return "索引更新于 \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// 已安装的插件有完整详情页（启用、命令、更新、卸载），未安装的只有索引字段。
    private func open(_ entry: PluginStoreEntry) {
        route = installedPlugins[entry.id] == nil ? .storeDetails(entry.id) : .details(entry.id)
    }

    private func install(_ entry: PluginStoreEntry) {
        installation.installFromStore(
            address: entry.installAddress(source: .official), pluginID: entry.id, pluginName: entry.name)
    }
}

private struct PluginStoreRow: View {
    let entry: PluginStoreEntry
    let state: PluginStoreEntry.State
    let installed: InstalledPluginDescriptor?
    let isBusy: Bool
    let requestDetails: () -> Void
    let requestInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 与插件列表一致：整块信息区都是详情入口，动作按钮独立。
            Button(action: requestDetails) {
                HStack(spacing: 12) {
                    PluginStoreIcon(entry: entry, installed: installed)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        if let summary = entry.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(entry.name) 详情")
            .accessibilityIdentifier("settings.pluginStoreDetails.\(entry.id)")
            action
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var detail: String {
        var parts = [entry.version, "\(entry.commands.count) 个命令"]
        if let runtime = entry.runtime { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled:
            if entry.isCompatibleWithHost() {
                Button("安装", action: requestInstall)
                    .disabled(isBusy)
                    .accessibilityIdentifier("settings.pluginStoreInstall.\(entry.id)")
            } else {
                Text("需要 Leap \(entry.minimumHostVersion ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Text("已安装")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.pluginStoreInstalled.\(entry.id)")
        case .updatable:
            Button("更新到 \(entry.version)", action: requestInstall)
                .disabled(isBusy)
                .accessibilityIdentifier("settings.pluginStoreUpdate.\(entry.id)")
        }
    }
}

/// 已安装的插件直接用本机图标，未安装的按索引里的相对路径远程加载，失败回落符号占位。
/// 商店详情页也用它，故不设为 private。
struct PluginStoreIcon: View {
    let entry: PluginStoreEntry
    let installed: InstalledPluginDescriptor?

    private var runtime: PluginManifest.Runtime? {
        entry.runtime.flatMap(PluginManifest.Runtime.init(rawValue:))
    }

    var body: some View {
        if let installed {
            PluginIcon(plugin: installed)
        } else if let iconURL = entry.iconURL(source: .official) {
            AsyncImage(url: iconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    PluginIcon(iconURL: nil, runtime: runtime)
                }
            }
        } else {
            PluginIcon(iconURL: nil, runtime: runtime)
        }
    }
}
