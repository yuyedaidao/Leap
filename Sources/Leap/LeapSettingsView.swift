import SwiftUI

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
                LeapSettingsView(coordinator: coordinator, appearance: appearance)
            } else {
                ContentUnavailableView("设置暂不可用", systemImage: "exclamationmark.triangle")
                    .frame(width: 620, height: 420)
            }
        }
        .background(SettingsWindowRegistration(presenter: appDelegate.settingsWindowPresenter))
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
    private enum Tab: Hashable {
        case general
        case plugins
        case data
        case about
    }

    let coordinator: SettingsCoordinator
    let appearance: Binding<AppearancePreference>
    @State private var selectedTab = Tab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPage(coordinator: coordinator, appearance: appearance)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)
            PluginSettingsPage(installation: coordinator.pluginInstallation)
                .tabItem { Label("插件", systemImage: "puzzlepiece.extension") }
                .tag(Tab.plugins)
            DataSettingsPage(coordinator: coordinator)
                .tabItem { Label("数据与隐私", systemImage: "externaldrive") }
                .tag(Tab.data)
            AboutSettingsPage()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 680, height: 460)
    }
}
