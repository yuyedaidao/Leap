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
        }
    }
}
