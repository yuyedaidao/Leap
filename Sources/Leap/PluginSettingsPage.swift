import AppKit
import LeapCore
import SwiftUI
import UniformTypeIdentifiers
import YQLogger

struct PluginSettingsPage: View {
    let installation: PluginInstallationModel
    @Binding var selectedPluginID: String?

    @State private var isImporterPresented = false
    @State private var isInstallChoicePresented = false
    @State private var isUninstallConfirmationPresented = false
    @State private var pluginPendingUninstall: InstalledPluginDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PluginSettingsBrowser(
                plugins: installation.plugins,
                selectedPluginID: $selectedPluginID,
                isEnabled: installation.isEnabled,
                setEnabled: { plugin, enabled in installation.setEnabled(enabled, for: plugin) },
                requestInstall: { isInstallChoicePresented = true },
                requestUpdate: { isImporterPresented = true },
                requestUninstall: {
                    pluginPendingUninstall = $0
                    isUninstallConfirmationPresented = true
                }
            )
            if let error = installation.errorMessage {
                SettingsErrorMessage(error)
            }
        }
        .padding(24)
        .confirmationDialog("安装插件", isPresented: $isInstallChoicePresented, titleVisibility: .visible) {
            Button("从本地目录安装") { isImporterPresented = true }
                .accessibilityIdentifier("settings.installLocalPlugin")
            Button("从远程地址安装") { installation.presentRemoteInstallation() }
                .accessibilityIdentifier("settings.installRemotePlugin")
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: remotePresentationBinding) {
            RemotePluginInstallView(installation: installation)
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder], onCompletion: inspectPlugin)
        .confirmationDialog(
            "确认安装插件？",
            isPresented: installationConfirmationBinding,
            titleVisibility: .visible,
            presenting: installation.candidate,
            actions: installConfirmationActions,
            message: installConfirmationMessage
        )
        .confirmationDialog(
            "永久卸载插件？",
            isPresented: $isUninstallConfirmationPresented,
            titleVisibility: .visible,
            presenting: pluginPendingUninstall,
            actions: uninstallConfirmationActions,
            message: uninstallConfirmationMessage
        )
    }

    private var installationConfirmationBinding: Binding<Bool> {
        Binding(
            get: { installation.isConfirmationPresented },
            set: { installation.isConfirmationPresented = $0 }
        )
    }

    private var remotePresentationBinding: Binding<Bool> {
        @Bindable var installation = installation
        return $installation.isRemotePresented
    }

    private func inspectPlugin(_ result: Result<URL, Error>) {
        switch result {
        case let .success(directory):
            let accessed = directory.startAccessingSecurityScopedResource()
            installation.inspect(directory: directory, isSecurityScoped: accessed)
        case let .failure(error):
            installation.inspectFailure(error)
        }
    }

    @ViewBuilder
    private func installConfirmationActions(_ candidate: PluginInstallCandidate) -> some View {
        Button("安装 \(candidate.manifest.name)") {
            installation.confirmInstallation()
        }
        Button("取消", role: .cancel) {
            installation.rejectInstallation()
        }
    }

    private func installConfirmationMessage(_ candidate: PluginInstallCandidate) -> Text {
        let commands = candidate.manifest.commands.map(\.title).formatted()
        let shellWarning = candidate.manifest.runtime == .shell
            ? "\nShell 插件将通过 zsh 执行任意本地命令。"
            : ""
        return Text(
            "\(candidate.manifest.name) \(candidate.manifest.version)\n" +
                "运行时：\(candidate.manifest.runtime.rawValue)\n命令：\(commands)" + shellWarning +
                (installation.replacementMessage.map { "\n" + $0 } ?? "")
        )
    }

    @ViewBuilder
    private func uninstallConfirmationActions(_ plugin: InstalledPluginDescriptor) -> some View {
        Button("卸载 \(plugin.manifest.name)", role: .destructive) {
            installation.uninstall(plugin)
            pluginPendingUninstall = nil
            isUninstallConfirmationPresented = false
        }
        Button("取消", role: .cancel) {
            pluginPendingUninstall = nil
        }
    }

    private func uninstallConfirmationMessage(_ plugin: InstalledPluginDescriptor) -> Text {
        Text("这会永久删除 Leap 受管的 \(plugin.manifest.name) 副本和信任记录，源目录不会受到影响。")
    }
}

/// 只保存插件 ID，更新后从最新目录取详情，避免把旧清单快照留在页面中。
private struct PluginSettingsBrowser: View {
    let plugins: [InstalledPluginDescriptor]
    @Binding var selectedPluginID: String?
    let isEnabled: (InstalledPluginDescriptor) -> Bool
    let setEnabled: (InstalledPluginDescriptor, Bool) -> Void
    let requestInstall: () -> Void
    let requestUpdate: () -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    @State private var query = PluginLibraryQuery()

    private static let logger = YQLogger(label: "com.padding.leap/plugin-details")

    var body: some View {
        if let plugin = plugins.first(where: { $0.id == selectedPluginID }) {
            PluginDetailsView(
                plugin: plugin,
                isEnabled: isEnabled(plugin),
                setEnabled: { setEnabled(plugin, $0) },
                requestUpdate: requestUpdate,
                requestUninstall: { requestUninstall(plugin) }
            )
            .id(plugin.id)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                PluginList(
                    plugins: plugins,
                    query: query,
                    isEnabled: isEnabled,
                    setEnabled: setEnabled,
                    requestDetails: {
                        selectedPluginID = $0
                        Self.logger.debug("已打开插件详情：\($0)。")
                    },
                    requestUpdate: requestUpdate,
                    requestUninstall: requestUninstall
                )
            }
            .searchable(text: $query.searchText, placement: .toolbar, prompt: "搜索插件或命令")
            .toolbar {
                ToolbarItem(id: "plugin-source", placement: .principal) {
                    PluginSourcePicker(source: $query.source)
                        .frame(width: 220)
                }
                // 用系统弹性间隔分开居中的筛选与右侧操作区。
                ToolbarSpacer(.flexible, placement: .principal)
                ToolbarItem(id: "plugin-install", placement: .primaryAction) {
                    Button("安装插件", systemImage: "plus", action: requestInstall)
                        .labelStyle(.iconOnly)
                        .help("安装插件")
                        .accessibilityIdentifier("settings.installPluginButton")
                }
            }
        }
    }
}

private struct PluginSourcePicker: View {
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

private struct PluginList: View {
    let plugins: [InstalledPluginDescriptor]
    let query: PluginLibraryQuery
    let isEnabled: (InstalledPluginDescriptor) -> Bool
    let setEnabled: (InstalledPluginDescriptor, Bool) -> Void
    let requestDetails: (String) -> Void
    let requestUpdate: () -> Void
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
            requestUpdate: requestUpdate,
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
                    Button("从本地目录更新…", action: requestUpdate)
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

struct PluginManagementActions: View {
    let origin: InstalledPluginDescriptor.Origin
    let requestUpdate: () -> Void
    let requestUninstall: () -> Void

    var body: some View {
        HStack {
            if origin == .official {
                Text("内置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("随 Leap 更新，无需单独安装。")
            } else {
                Button("更新", action: requestUpdate)
                Button("卸载", role: .destructive, action: requestUninstall)
            }
        }
        // List 内的管理按钮独立响应，不让安装或卸载操作同时打开详情。
        .buttonStyle(.borderless)
    }
}

struct PluginIcon: View {
    let plugin: InstalledPluginDescriptor

    var body: some View {
        if let iconURL = plugin.iconURL, let image = NSImage(contentsOf: iconURL) {
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
        switch plugin.manifest.runtime {
        case .python: "chevron.left.forwardslash.chevron.right"
        case .javascript: "curlybraces"
        case .shell: "terminal"
        }
    }
}
