import LeapCore
import SwiftUI
import YQLogger

struct LeapSettingsRootView: View {
    let appDelegate: AppDelegate
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if let coordinator = appDelegate.settingsCoordinator {
                LeapSettingsView(coordinator: coordinator, appearance: appearance, updates: appDelegate.appUpdates)
            } else {
                ContentUnavailableView("设置暂不可用", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 原生导航会参与窗口尺寸协商，根内容也声明下限，避免切页后约束丢失。
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .onAppear {
            appDelegate.applyAppearancePreference(currentAppearance)
        }
        .onChange(of: appearanceRaw) {
            appDelegate.applyAppearancePreference(currentAppearance)
        }
    }

    private var currentAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }
}

private struct LeapSettingsView: View {
    let coordinator: SettingsCoordinator
    let appearance: Binding<AppearancePreference>
    let updates: AppUpdateController
    @State private var selectedSection: SettingsSection? = .general
    @State private var pluginRoute: PluginSettingsRoute = .list
    private static let logger = YQLogger(label: "com.padding.leap/settings-navigation")

    private var selectedPlugin: InstalledPluginDescriptor? {
        guard case let .details(pluginID) = pluginRoute else { return nil }
        return coordinator.pluginInstallation.plugins.first { $0.id == pluginID }
    }

    private var detailTitle: String {
        guard selectedSection == .plugins else { return (selectedSection ?? .general).title }
        switch pluginRoute {
        case .list: return SettingsSection.plugins.title
        case .store: return "插件商店"
        case .details: return selectedPlugin?.manifest.name ?? SettingsSection.plugins.title
        case let .storeDetails(entryID):
            return coordinator.pluginStore.entry(id: entryID)?.name ?? "插件商店"
        }
    }

    /// 商店详情是商店的子页，其余详情都回到插件列表。
    private var backTarget: PluginSettingsRoute {
        if case .storeDetails = pluginRoute { return .store }
        return .list
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selectedSection ?? .general {
                case .general:
                    GeneralSettingsPage(coordinator: coordinator, appearance: appearance, updates: updates)
                case .plugins:
                    PluginSettingsPage(
                        installation: coordinator.pluginInstallation,
                        store: coordinator.pluginStore,
                        route: $pluginRoute
                    )
                case .data:
                    DataSettingsPage(coordinator: coordinator)
                case .about:
                    AboutSettingsPage(updates: updates)
                }
            }
            .navigationTitle(detailTitle)
            .toolbar {
                if selectedSection == .plugins, pluginRoute != .list {
                    ToolbarItem(placement: .navigation) {
                        Button { pluginRoute = backTarget } label: {
                            Label(backTarget == .store ? "返回插件商店" : "返回插件列表", systemImage: "chevron.left")
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("settings.pluginDetails.back")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedSection) { _, section in
            Self.logger.debug("设置分类已切换：\(section?.rawValue ?? "general")。")
        }
        .onChange(of: coordinator.pluginInstallation.plugins) { _, plugins in
            // 在根视图处理失效详情，即使用户正浏览其他分类也不会保留已卸载插件。
            guard case let .details(pluginID) = pluginRoute,
                !plugins.contains(where: { $0.id == pluginID }) else { return }
            pluginRoute = .list
            Self.logger.debug("插件详情已失效，返回插件列表：\(pluginID)。")
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case plugins
    case data
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .plugins: "插件"
        case .data: "数据与隐私"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .plugins: "puzzlepiece.extension"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.icon)
                .tag(section)
                .accessibilityIdentifier("settings.section.\(section.rawValue)")
        }
        .listStyle(.sidebar)
    }
}
