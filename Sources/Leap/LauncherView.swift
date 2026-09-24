import AppKit
import LeapCore
import SwiftUI

struct LauncherView: View {
    let model: LauncherModel
    private let contentHeightDidChange: (CGFloat) -> Void
    private let hideForSettings: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue
    @State private var selectedSearchResultID: LauncherItem.ID?
    @State private var selectedRecentItemID: LauncherItem.ID?

    init(
        model: LauncherModel,
        contentHeightDidChange: @escaping (CGFloat) -> Void = { _ in },
        hideForSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        self.contentHeightDidChange = contentHeightDidChange
        self.hideForSettings = hideForSettings
    }

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 20) {
            LauncherSearchHeader(
                query: $model.query,
                isFocused: $isSearchFieldFocused,
                hideForSettings: hideForSettings,
                submit: activateSelectedItem,
                moveSearchSelection: moveSearchSelection,
                moveRecentSelection: moveRecentSelection
            )
            LauncherContent(
                query: model.query,
                searchResults: model.searchResults,
                recentItems: model.recentItems,
                selectedSearchResultID: selectedSearchResultID,
                selectedRecentItemID: selectedRecentItemID,
                activate: model.activate
            )
            if model.invocationState != .idle {
                LauncherInvocationFeedback(
                    state: model.invocationState,
                    stopForegroundShell: model.stopForegroundShell
                )
            }
        }
        .padding(24)
        .frame(width: 800)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .ignoresSafeArea()
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
        .preferredColorScheme((AppearancePreference(rawValue: appearanceRaw) ?? .system).colorScheme)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            contentHeightDidChange(height)
        }
        .onAppear(perform: model.reloadPlugins)
        .onChange(of: model.query) {
            resetSelections()
        }
        .onChange(of: model.searchResults.map(\.id)) {
            selectedSearchResultID = model.searchResults.first?.id
        }
        .onChange(of: model.recentItems.map(\.id)) {
            selectedRecentItemID = model.recentItems.first?.id
        }
        .onChange(of: model.focusRequestID, initial: true) {
            isSearchFieldFocused = true
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

    private var hasSearchResults: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.searchResults.isEmpty
    }

    private func resetSelections() {
        selectedSearchResultID = model.searchResults.first?.id
        selectedRecentItemID = model.recentItems.first?.id
    }

    private func moveSearchSelection(_ offset: Int) -> Bool {
        guard hasSearchResults else { return false }
        selectedSearchResultID = movedItemID(
            from: selectedSearchResultID,
            in: model.searchResults,
            offset: offset
        )
        return true
    }

    private func moveRecentSelection(_ offset: Int) -> Bool {
        guard !hasSearchResults, !model.recentItems.isEmpty else { return false }
        selectedRecentItemID = movedItemID(
            from: selectedRecentItemID,
            in: model.recentItems,
            offset: offset
        )
        return true
    }

    private func movedItemID(from selectedID: LauncherItem.ID?, in items: [LauncherItem], offset: Int) -> LauncherItem.ID? {
        guard let first = items.first else { return nil }
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return first.id
        }
        return items[min(max(index + offset, 0), items.count - 1)].id
    }

    private func activateSelectedItem() {
        let items = hasSearchResults ? model.searchResults : model.recentItems
        let selectedID = hasSearchResults ? selectedSearchResultID : selectedRecentItemID
        guard let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
        model.activate(item)
    }
}

private struct LauncherSearchHeader: View {
    @Environment(\.openSettings) private var openSettings
    @Binding var query: String
    let isFocused: FocusState<Bool>.Binding
    let hideForSettings: () -> Void
    let submit: () -> Void
    let moveSearchSelection: (Int) -> Bool
    let moveRecentSelection: (Int) -> Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("搜索功能 / 粘贴文件、图片", text: $query)
                .accessibilityIdentifier("launcher.searchField")
                .textFieldStyle(.plain)
                .font(.title)
                .focused(isFocused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) {
                    moveSearchSelection(-1) ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    moveSearchSelection(1) ? .handled : .ignored
                }
                .onKeyPress(.leftArrow) {
                    moveRecentSelection(-1) ? .handled : .ignored
                }
                .onKeyPress(.rightArrow) {
                    moveRecentSelection(1) ? .handled : .ignored
                }

            Button {
                hideForSettings()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .resizable()
                    .font(.body)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("launcher.settingsButton")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
        .background(.tertiary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    LauncherSearchHeaderPreview()
}

private struct LauncherSearchHeaderPreview: View {
    @FocusState private var isFocused: Bool
    @State private var query = "hello"

    var body: some View {
        LauncherSearchHeader(
            query: $query,
            isFocused: $isFocused,
            hideForSettings: {},
            submit: {},
            moveSearchSelection: { _ in false },
            moveRecentSelection: { _ in false }
        )
            .onAppear {
                isFocused = true
            }
    }
}

private struct LauncherContent: View {
    let query: String
    let searchResults: [LauncherItem]
    let recentItems: [LauncherItem]
    let selectedSearchResultID: LauncherItem.ID?
    let selectedRecentItemID: LauncherItem.ID?
    let activate: (LauncherItem) -> Void

    var body: some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !searchResults.isEmpty {
            LauncherSearchResults(items: searchResults, selectedItemID: selectedSearchResultID, activate: activate)
        } else if !recentItems.isEmpty {
            RecentCommandsSection(items: recentItems, selectedItemID: selectedRecentItemID, activate: activate)
        }
    }
}

private struct RecentCommandsSection: View {
    let items: [LauncherItem]
    let selectedItemID: LauncherItem.ID?
    let activate: (LauncherItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近使用")
                .font(.headline)

            CommandGrid(items: items, selectedItemID: selectedItemID, activate: activate)
        }
    }
}

private struct LauncherSearchResults: View {
    let items: [LauncherItem]
    let selectedItemID: LauncherItem.ID?
    let activate: (LauncherItem) -> Void

    private let rowHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 4
    private let maximumVisibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("搜索结果")
                .font(.headline)

            ScrollView(.vertical) {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(items) { item in
                        SearchResultRow(item: item, isSelected: item.id == selectedItemID, activate: activate)
                            .frame(height: rowHeight)
                    }
                }
            }
            .frame(height: visibleListHeight)
            .accessibilityIdentifier("launcher.searchResults")
        }
    }

    private var visibleListHeight: CGFloat {
        let visibleCount = min(items.count, maximumVisibleRows)
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(0, visibleCount - 1)) * rowSpacing
    }
}

private struct SearchResultRow: View {
    let item: LauncherItem
    let isSelected: Bool
    let activate: (LauncherItem) -> Void

    var body: some View {
        Button {
            activate(item)
        } label: {
            HStack(spacing: 12) {
                LauncherItemIcon(item: item)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.accessibilityID)
        .accessibilityLabel(item.title)
    }
}

private struct CommandGrid: View {
    let items: [LauncherItem]
    let selectedItemID: LauncherItem.ID?
    let activate: (LauncherItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                CommandCard(item: item, isSelected: item.id == selectedItemID, activate: activate)
            }
        }
        .accessibilityIdentifier("launcher.commandGrid")
    }
}

private struct CommandCard: View {
    let item: LauncherItem
    let isSelected: Bool
    let activate: (LauncherItem) -> Void

    var body: some View {
        Button {
            activate(item)
        } label: {
            VStack(spacing: 7) {
                LauncherItemIcon(item: item)
                    .frame(width: 38, height: 38)
                Text(item.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.accessibilityID)
        .accessibilityLabel(item.title)
    }
}

@MainActor
private enum SystemApplicationIconCache {
    static let images = NSCache<NSString, NSImage>()
}

private struct LauncherItemIcon: View {
    let item: LauncherItem

    var body: some View {
        switch item {
        case let .application(application):
            Image(nsImage: icon(for: application))
                .resizable()
                .scaledToFit()
        case let .plugin(command):
            CommandIcon(iconURL: command.iconURL, runtime: command.manifest.runtime)
        }
    }

    private func icon(for application: SystemApplicationDescriptor) -> NSImage {
        let key = application.path as NSString
        if let cached = SystemApplicationIconCache.images.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: application.path)
        SystemApplicationIconCache.images.setObject(icon, forKey: key)
        return icon
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
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var iconName: String {
        switch runtime {
        case .python: "chevron.left.forwardslash.chevron.right"
        case .javascript: "curlybraces"
        case .shell: "terminal"
        }
    }
}

private struct LauncherInvocationFeedback: View {
    let state: LauncherModel.InvocationState
    let stopForegroundShell: () -> Void

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
        case let .shellOutput(title, output, isRunning):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        isRunning ? "正在运行 \(title)…" : "\(title) 已结束",
                        systemImage: isRunning ? "terminal" : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if isRunning {
                        Button("停止", role: .destructive, action: stopForegroundShell)
                            .accessibilityIdentifier("launcher.stopShellButton")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output.isEmpty ? "正在等待输出…" : output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("shellOutputEnd")
                    }
                    .frame(maxHeight: 220)
                    .onAppear { proxy.scrollTo("shellOutputEnd", anchor: .bottom) }
                    .onChange(of: output) { proxy.scrollTo("shellOutputEnd", anchor: .bottom) }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("launcher.shellOutput")
            }
        }
    }
}
