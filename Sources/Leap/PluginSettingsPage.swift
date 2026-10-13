import AppKit
import LeapCore
import SwiftUI
import UniformTypeIdentifiers
import YQLogger

struct PluginSettingsPage: View {
    let installation: PluginInstallationModel
    @Binding var selectedPluginID: String?

    @State private var isImporterPresented = false
    @State private var isUninstallConfirmationPresented = false
    @State private var pluginPendingUninstall: InstalledPluginDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PluginSettingsBrowser(
                plugins: installation.plugins,
                selectedPluginID: $selectedPluginID,
                requestInstall: { isImporterPresented = true },
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
                "运行时：\(candidate.manifest.runtime.rawValue)\n命令：\(commands)" + shellWarning
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
    let requestInstall: () -> Void
    let requestUpdate: () -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    private static let logger = YQLogger(label: "com.padding.leap/plugin-details")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let plugin = plugins.first(where: { $0.id == selectedPluginID }) {
                PluginDetailsView(
                    plugin: plugin,
                    requestBack: { selectedPluginID = nil },
                    requestUpdate: requestUpdate,
                    requestUninstall: { requestUninstall(plugin) }
                )
                .id(plugin.id)
            } else {
                PluginSettingsHeader(requestInstall: requestInstall)
                PluginList(
                    plugins: plugins,
                    requestDetails: {
                        selectedPluginID = $0
                        Self.logger.debug("已打开插件详情：\($0)。")
                    },
                    requestUpdate: requestUpdate,
                    requestUninstall: requestUninstall
                )
            }
        }
    }
}

private struct PluginSettingsHeader: View {
    let requestInstall: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("本地插件")
                    .font(.title2.bold())
                Text("官方插件随 Leap 提供；本地插件需安装确认后使用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("安装本地插件", action: requestInstall)
                .accessibilityIdentifier("settings.installPluginButton")
        }
    }
}

private struct PluginList: View {
    let plugins: [InstalledPluginDescriptor]
    let requestDetails: (String) -> Void
    let requestUpdate: () -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    var body: some View {
        if plugins.isEmpty {
            ContentUnavailableView(
                "没有已安装插件",
                systemImage: "puzzlepiece.extension",
                description: Text("选择插件目录后，Leap 会验证清单并复制受管副本。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(plugins) { plugin in
                PluginRow(
                    plugin: plugin,
                    requestDetails: { requestDetails(plugin.id) },
                    requestUpdate: requestUpdate,
                    requestUninstall: requestUninstall
                )
            }
            .listStyle(.inset)
        }
    }
}

private struct PluginRow: View {
    let plugin: InstalledPluginDescriptor
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
                            "\(plugin.manifest.version) · \(plugin.manifest.runtime.rawValue) · " +
                                "\(plugin.manifest.commands.count) 个命令"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(plugin.manifest.name) 详情")
            .accessibilityIdentifier("settings.pluginDetails.\(plugin.id)")
            PluginManagementActions(
                origin: plugin.origin, requestUpdate: requestUpdate,
                requestUninstall: { requestUninstall(plugin) }
            )
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
                Text("官方内置")
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
