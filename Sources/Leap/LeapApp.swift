import SwiftUI

@main
@MainActor
struct LeapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            LeapSettingsRootView(appDelegate: appDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            LeapSettingsCommands(appDelegate: appDelegate)
        }
    }
}

private struct LeapSettingsCommands: Commands {
    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                appDelegate.showSettings(source: "菜单或快捷键")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
