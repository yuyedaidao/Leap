import AppKit
import LeapCore
import SwiftUI
import YQLogger

/// 插件列表相关的展示组件：来源筛选、分组列表、行与图标。
struct PluginSourcePicker: View {
    @Binding var source: PluginLibraryQuery.Source

    var body: some View {
        Picker("插件来源", selection: $source) {
            ForEach(PluginLibraryQuery.Source.allCases, id: \.self) { source in
                Text(title(for: source))
                    .tag(source)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.pluginSource")
    }

    private func title(for source: PluginLibraryQuery.Source) -> String {
        switch source {
        case .all: "全部"
        case .local: "自定义"
        case .official: "内置"
        }
    }
}

struct PluginList: View {
    let plugins: [InstalledPluginDescriptor]
    let query: PluginLibraryQuery
    let isEnabled: (InstalledPluginDescriptor) -> Bool
    let setEnabled: (InstalledPluginDescriptor, Bool) -> Void
    let requestDetails: (String) -> Void
    let requestUpdate: (String) -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    var body: some View {
        let visible = plugins.filter(query.includes)
        let local = visible.filter { $0.origin == .local }
        let official = visible.filter { $0.origin == .official }
        if visible.isEmpty {
            ContentUnavailableView(
                query.term.isEmpty ? "暂无此类插件" : "没有匹配的插件",
                systemImage: query.term.isEmpty ? "puzzlepiece.extension" : "magnifyingglass",
                description: Text(query.term.isEmpty ? "可安装本地插件，或切换来源查看其他插件。" : "尝试其他关键词或切换插件来源。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("settings.pluginEmptyState")
        } else {
            List {
                if !local.isEmpty {
                    Section {
                        ForEach(local) { plugin in
                            row(plugin)
                        }
                    } header: {
                        Text("自定义 · \(local.count)")
                            .accessibilityIdentifier("settings.pluginGroup.local")
                    }
                }
                if !official.isEmpty {
                    Section {
                        ForEach(official) { plugin in
                            row(plugin)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("内置 · \(official.count)")
                                .accessibilityIdentifier("settings.pluginGroup.official")
                            Text("随 Leap 提供，随应用更新")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ plugin: InstalledPluginDescriptor) -> some View {
        PluginRow(
            plugin: plugin,
            matchingCommands: query.matchingCommands(in: plugin).map(\.title),
            isEnabled: isEnabled(plugin),
            setEnabled: { setEnabled(plugin, $0) },
            requestDetails: { requestDetails(plugin.id) },
            requestUpdate: { requestUpdate(plugin.id) },
            requestUninstall: requestUninstall
        )
    }
}

private struct PluginRow: View {
    let plugin: InstalledPluginDescriptor
    let matchingCommands: [String]
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void
    let requestDetails: () -> Void
    let requestUpdate: () -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: requestDetails) {
                HStack(spacing: 12) {
                    PluginIcon(plugin: plugin)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.manifest.name)
                        Text(
                            "\(plugin.manifest.version) · \(plugin.manifest.commands.count) 个命令" +
                                (isEnabled ? "" : " · 已禁用")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !matchingCommands.isEmpty {
                            Text("匹配命令：\(matchingCommands.joined(separator: "、"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(matchingCommands.joined(separator: "、"))
                                .accessibilityIdentifier("settings.pluginMatch.\(plugin.id)")
                        }
                    }
                    .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                matchingCommands.isEmpty
                    ? "查看 \(plugin.manifest.name) 详情"
                    : "查看 \(plugin.manifest.name) 详情，匹配命令：\(matchingCommands.joined(separator: "、"))"
            )
            .accessibilityIdentifier("settings.pluginDetails.\(plugin.id)")
            Toggle("启用", isOn: Binding(get: { isEnabled }, set: setEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(isEnabled ? "禁用 \(plugin.manifest.name)" : "启用 \(plugin.manifest.name)")
                .accessibilityLabel("启用 \(plugin.manifest.name)")
                .accessibilityIdentifier("settings.pluginEnabled.\(plugin.id)")
            if plugin.origin == .local {
                Menu {
                    Button("更新", action: requestUpdate)
                    Button("卸载", role: .destructive) { requestUninstall(plugin) }
                } label: {
                    Label("管理插件", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                // 保留系统按钮的边框与点击范围，避免菜单热区缩成省略号图标。
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .controlSize(.regular)
                .help("管理插件")
                .accessibilityLabel("管理 \(plugin.manifest.name)")
                .accessibilityIdentifier("settings.pluginMenu.\(plugin.id)")
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

struct PluginIcon: View {
    let iconURL: URL?
    let runtime: PluginManifest.Runtime?

    init(iconURL: URL?, runtime: PluginManifest.Runtime?) {
        self.iconURL = iconURL
        self.runtime = runtime
    }

    init(plugin: InstalledPluginDescriptor) {
        self.init(iconURL: plugin.iconURL, runtime: plugin.manifest.runtime)
    }

    var body: some View {
        if let iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var iconName: String {
        switch runtime {
        case .python: "chevron.left.forwardslash.chevron.right"
        case .javascript: "curlybraces"
        case .shell: "terminal"
        case nil: "puzzlepiece.extension"
        }
    }
}
