import AppKit
import LeapCore
import SwiftUI
import UniformTypeIdentifiers
import YQLogger

/// 插件页内部的三种态共用一个详情列，商店与列表/详情互斥切换。
enum PluginSettingsRoute: Equatable {
    case list
    case details(String)
    case store
}

struct PluginSettingsPage: View {
    let installation: PluginInstallationModel
    let store: PluginStoreModel
    @Binding var route: PluginSettingsRoute

    @State private var isImporterPresented = false
    @State private var isSourceChoicePresented = false
    @State private var sourceChoiceUpdateID: String?
    @State private var isUninstallConfirmationPresented = false
    @State private var pluginPendingUninstall: InstalledPluginDescriptor?

    var body: some View {
        content
        .confirmationDialog(
            sourceChoiceUpdateID == nil ? "安装插件" : "更新插件",
            isPresented: $isSourceChoicePresented,
            titleVisibility: .visible,
            actions: sourceChoiceActions
        )
        .sheet(isPresented: remotePresentationBinding) {
            RemotePluginInstallView(installation: installation)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: inspectPlugin,
            onCancellation: { sourceChoiceUpdateID = nil }
        )
        .confirmationDialog(
            installation.isUpdating ? "确认更新插件？" : "确认安装插件？",
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

    /// 商店页占满详情列并自带留白；列表与详情保持原有内边距。
    @ViewBuilder
    private var content: some View {
        switch route {
        case .store:
            PluginStorePage(installation: installation, store: store, route: $route)
        case .list:
            listContent
        case let .details(pluginID):
            detailsContent(pluginID)
        }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            PluginSettingsBrowser(
                plugins: installation.plugins,
                route: $route,
                isEnabled: installation.isEnabled,
                setEnabled: { plugin, enabled in installation.setEnabled(enabled, for: plugin) },
                requestInstall: { presentSourceChoice() },
                requestUpdate: requestUpdate,
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
    }

    @ViewBuilder
    private func detailsContent(_ pluginID: String) -> some View {
        if let plugin = installation.plugins.first(where: { $0.id == pluginID }) {
            PluginDetailsView(
                plugin: plugin,
                isEnabled: installation.isEnabled(plugin),
                setEnabled: { installation.setEnabled($0, for: plugin) },
                requestUpdate: { requestUpdate(plugin.id) },
                requestUninstall: {
                    pluginPendingUninstall = plugin
                    isUninstallConfirmationPresented = true
                }
            )
            .id(plugin.id)
        } else {
            ContentUnavailableView("插件已不可用", systemImage: "puzzlepiece.extension")
        }
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

    /// 商店里登记过的插件一键更新；其余插件仍走本地/远程来源选择。
    private func requestUpdate(_ pluginID: String) {
        Task {
            await store.loadIfNeeded()
            guard let entry = store.entry(id: pluginID) else {
                presentSourceChoice(updating: pluginID)
                return
            }
            route = .store
            installation.installFromStore(address: entry.installAddress(source: .official), pluginID: pluginID)
        }
    }

    private func presentSourceChoice(updating pluginID: String? = nil) {
        sourceChoiceUpdateID = pluginID
        isSourceChoicePresented = true
    }

    @ViewBuilder
    private func sourceChoiceActions() -> some View {
        Button(sourceChoiceUpdateID == nil ? "从本地目录安装" : "从本地目录更新") {
            isImporterPresented = true
        }
        .accessibilityIdentifier("settings.installLocalPlugin")
        Button(sourceChoiceUpdateID == nil ? "从远程地址安装" : "从远程地址更新") {
            installation.presentRemoteInstallation(updating: sourceChoiceUpdateID)
            sourceChoiceUpdateID = nil
        }
        .accessibilityIdentifier("settings.installRemotePlugin")
        Button("取消", role: .cancel) { sourceChoiceUpdateID = nil }
    }

    private func inspectPlugin(_ result: Result<[URL], Error>) {
        defer { sourceChoiceUpdateID = nil }
        switch result {
        case let .success(directories):
            guard let directory = directories.first else { return }
            let accessed = directory.startAccessingSecurityScopedResource()
            installation.inspect(directory: directory, isSecurityScoped: accessed, updating: sourceChoiceUpdateID)
        case let .failure(error):
            installation.inspectFailure(error)
        }
    }

    @ViewBuilder
    private func installConfirmationActions(_ candidate: PluginInstallCandidate) -> some View {
        Button(installation.isUpdating ? "更新 \(candidate.manifest.name)" : "安装 \(candidate.manifest.name)") {
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
        // 远程候选要能看到实际安装的来源目录与固定提交。
        let sourceLine = candidate.source.map {
            "\n来源：\($0.owner)/\($0.repository)/\($0.path)\n提交：\(String($0.commit.prefix(7)))"
        } ?? ""
        return Text(
            "\(candidate.manifest.name) \(candidate.manifest.version)\n" +
                "运行时：\(candidate.manifest.runtime.rawValue)\n命令：\(commands)" + shellWarning + sourceLine +
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
    @Binding var route: PluginSettingsRoute
    let isEnabled: (InstalledPluginDescriptor) -> Bool
    let setEnabled: (InstalledPluginDescriptor, Bool) -> Void
    let requestInstall: () -> Void
    let requestUpdate: (String) -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    @State private var query = PluginLibraryQuery()

    private static let logger = YQLogger(label: "com.padding.leap/plugin-details")

    var body: some View {
        PluginList(
            plugins: plugins,
            query: query,
            isEnabled: isEnabled,
            setEnabled: setEnabled,
            requestDetails: {
                route = .details($0)
                Self.logger.debug("已打开插件详情：\($0)。")
            },
            requestUpdate: requestUpdate,
            requestUninstall: requestUninstall
        )
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
            // 商店入口紧贴系统搜索框，与安装按钮同属右侧操作区。
            ToolbarItem(id: "plugin-store", placement: .primaryAction) {
                Button("插件商店", systemImage: "storefront") { route = .store }
                    .labelStyle(.iconOnly)
                    .help("插件商店")
                    .accessibilityIdentifier("settings.pluginStoreButton")
            }
        }
    }
}
