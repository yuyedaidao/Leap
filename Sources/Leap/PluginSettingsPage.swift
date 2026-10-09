import AppKit
import LeapCore
import SwiftUI
import UniformTypeIdentifiers

struct PluginSettingsPage: View {
    let installation: PluginInstallationModel

    @State private var isImporterPresented = false
    @State private var isUninstallConfirmationPresented = false
    @State private var pluginPendingUninstall: InstalledPluginDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PluginSettingsHeader(requestInstall: { isImporterPresented = true })
            PluginList(
                plugins: installation.plugins,
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
    let requestUpdate: () -> Void
    let requestUninstall: (InstalledPluginDescriptor) -> Void

    var body: some View {
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
            if plugin.origin == .official {
                Text("官方内置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("随 Leap 更新，无需单独安装。")
            } else {
                Button("更新", action: requestUpdate)
                Button("卸载", role: .destructive) {
                    requestUninstall(plugin)
                }
            }
        }
    }
}

private struct PluginIcon: View {
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
