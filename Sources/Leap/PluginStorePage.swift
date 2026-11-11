import LeapCore
import SwiftUI

struct PluginStorePage: View {
    let installation: PluginInstallationModel
    let store: PluginStoreModel
    @Binding var route: PluginSettingsRoute

    @State private var query = PluginStoreQuery()

    private var installedVersions: [String: String] {
        Dictionary(installation.plugins.map { ($0.id, $0.manifest.version) }, uniquingKeysWith: { first, _ in first })
    }

    private var visibleEntries: [PluginStoreEntry] {
        store.entries.filter(query.includes)
    }

    private var isBusy: Bool { installation.isPreparing || installation.isInstalling }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isBusy { downloadBanner }
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
                            state: entry.state(installedVersion: installedVersions[entry.id]),
                            isBusy: isBusy,
                            requestInstall: { install(entry) }
                        )
                    }
                } header: {
                    Text("\(store.index?.name ?? "官方插件") · \(visibleEntries.count)")
                        .accessibilityIdentifier("settings.pluginStoreGroup")
                } footer: {
                    if let updatedAt = store.updatedAt {
                        Text("索引更新于 \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("settings.pluginStoreList")
        }
    }

    private var downloadBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(installation.remotePhase ?? "正在准备插件")
                    .accessibilityIdentifier("settings.pluginStorePhase")
                Spacer()
                Button("取消") { installation.rejectInstallation() }
                    .disabled(installation.isInstalling)
                    .accessibilityIdentifier("settings.pluginStoreCancel")
            }
            if let progress = installation.progress, progress.totalFiles > 0 {
                ProgressView(value: Double(progress.completedFiles), total: Double(progress.totalFiles))
                Text(
                    "\(progress.completedFiles) / \(progress.totalFiles) 个文件 · "
                        + progress.downloadedBytes.formatted(.byteCount(style: .file))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if installation.isPreparing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func install(_ entry: PluginStoreEntry) {
        installation.installFromStore(address: entry.installAddress(source: .official), pluginID: entry.id)
    }
}

private struct PluginStoreRow: View {
    let entry: PluginStoreEntry
    let state: PluginStoreEntry.State
    let isBusy: Bool
    let requestInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PluginIcon(iconURL: nil, runtime: entry.runtime.flatMap(PluginManifest.Runtime.init(rawValue:)))
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
            action
        }
        .accessibilityElement(children: .contain)
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
