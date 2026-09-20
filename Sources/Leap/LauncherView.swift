import AppKit
import LeapCore
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    let model: LauncherModel

    @FocusState private var isSearchFieldFocused: Bool
    @State private var isSettingsPresented = false

    var body: some View {
        @Bindable var model = model

        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.separator.opacity(0.45), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 20) {
                LauncherSearchHeader(
                    query: $model.query,
                    isFocused: $isSearchFieldFocused,
                    showSettings: { isSettingsPresented = true },
                    submit: model.activateFirstSearchResult
                )
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LauncherHomeContent(commands: model.recentCommands, activate: model.activate)
                } else {
                    LauncherSearchResults(commands: model.searchResults, activate: model.activate)
                }

                LauncherInvocationFeedback(state: model.invocationState)
            }
            .padding(24)
        }
        .ignoresSafeArea()
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
        .onAppear(perform: model.reloadPlugins)
        .onChange(of: model.focusRequestID, initial: true) {
            isSearchFieldFocused = true
        }
        .sheet(isPresented: $isSettingsPresented) {
            if let paths = model.pluginPaths {
                PluginSettingsView(paths: paths, launcher: model)
            } else {
                ContentUnavailableView("设置不可用", systemImage: "exclamationmark.triangle")
                    .frame(width: 420, height: 240)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.webCommand != nil },
                set: { if !$0 { model.dismissWebPlugin() } }
            )
        ) {
            if let command = model.webCommand {
                PluginWebSheet(
                    command: command,
                    invoke: { commandID, query in
                        await model.invokeFromWeb(command: command, commandID: commandID, query: query)
                    },
                    dismiss: model.dismissWebPlugin
                )
            }
        }
    }
}

private struct LauncherSearchHeader: View {
    @Binding var query: String
    let isFocused: FocusState<Bool>.Binding
    let showSettings: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("搜索功能 / 粘贴文件、图片", text: $query)
                .accessibilityIdentifier("launcher.searchField")
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(isFocused)
                .onSubmit(submit)

            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("launcher.settingsButton")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LauncherHomeContent: View {
    let commands: [PluginCommandDescriptor]
    let activate: (PluginCommandDescriptor) -> Void

    var body: some View {
        if commands.isEmpty {
            EmptyLauncherHint()
        } else {
            RecentCommandsSection(commands: commands, activate: activate)
        }
    }
}

private struct EmptyLauncherHint: View {
    var body: some View {
        ContentUnavailableView(
            "从这里开始",
            systemImage: "command",
            description: Text("在设置中安装本地插件，或直接输入命令搜索。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentCommandsSection: View {
    let commands: [PluginCommandDescriptor]
    let activate: (PluginCommandDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近使用")
                .font(.headline)

            CommandGrid(commands: commands, activate: activate)
        }
    }
}

private struct LauncherSearchResults: View {
    let commands: [PluginCommandDescriptor]
    let activate: (PluginCommandDescriptor) -> Void

    var body: some View {
        if commands.isEmpty {
            ContentUnavailableView("没有找到匹配命令", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("搜索结果")
                    .font(.headline)
                CommandGrid(commands: commands, activate: activate)
            }
        }
    }
}

private struct CommandGrid: View {
    let commands: [PluginCommandDescriptor]
    let activate: (PluginCommandDescriptor) -> Void

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(commands) { command in
                CommandCard(command: command, activate: activate)
            }
        }
        .accessibilityIdentifier("launcher.commandGrid")
    }
}

private struct CommandCard: View {
    let command: PluginCommandDescriptor
    let activate: (PluginCommandDescriptor) -> Void

    var body: some View {
        Button {
            activate(command)
        } label: {
            VStack(spacing: 7) {
                CommandIcon(iconURL: command.iconURL, runtime: command.manifest.runtime)
                    .frame(width: 38, height: 38)
                Text(command.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .top)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("launcher.command.\(command.id)")
        .accessibilityLabel("\(command.pluginName)：\(command.title)")
    }
}

private struct CommandIcon: View {
    let iconURL: URL?
    let runtime: PluginManifest.Runtime

    var body: some View {
        if let iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Image(systemName: runtime == .python ? "chevron.left.forwardslash.chevron.right" : "curlybraces")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct LauncherInvocationFeedback: View {
    let state: LauncherModel.InvocationState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case let .running(title):
            Label("正在运行 \(title)…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .result(text):
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .accessibilityIdentifier("launcher.pluginResult")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .accessibilityIdentifier("launcher.pluginError")
        }
    }
}

private struct PluginSettingsView: View {
    let paths: AppPaths
    let launcher: LauncherModel

    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var installation: PluginInstallationModel

    init(paths: AppPaths, launcher: LauncherModel) {
        self.paths = paths
        self.launcher = launcher
        _installation = State(initialValue: PluginInstallationModel(paths: paths, didInstall: launcher.reloadPlugins))
    }

    var body: some View {
        @Bindable var installation = installation

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Leap 设置")
                    .font(.title2.bold())
                Spacer()
                Button("完成", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }

            Text("本地插件会先校验清单，再复制到 Leap 的受管目录。首次安装或内容变化需要确认信任。")
                .foregroundStyle(.secondary)

            Button("安装本地插件") {
                isImporterPresented = true
            }
            .accessibilityIdentifier("launcher.installPluginButton")

            if let errorMessage = installation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 300)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(directory):
                let accessed = directory.startAccessingSecurityScopedResource()
                installation.inspect(directory: directory, isSecurityScoped: accessed)
            case let .failure(error):
                installation.inspectFailure(error)
            }
        }
        .confirmationDialog(
            "确认安装插件？",
            isPresented: $installation.isConfirmationPresented,
            titleVisibility: .visible,
            presenting: installation.candidate
        ) { candidate in
            Button("安装 \(candidate.manifest.name)") {
                installation.confirmInstallation()
            }
            Button("取消", role: .cancel) {
                installation.rejectInstallation()
            }
        } message: { candidate in
            Text("\(candidate.manifest.name) \(candidate.manifest.version)\n运行时：\(candidate.manifest.runtime.rawValue)\n命令：\(candidate.manifest.commands.map(\.title).formatted())")
        }
    }
}
