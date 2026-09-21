import Foundation
import LeapCore
import SwiftUI

@main
@MainActor
struct LeapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var testingModel = LauncherModel(
        fixtureCommands: [
            PluginCommandDescriptor(
                pluginID: "com.padding.leap.ui-test",
                pluginName: "测试插件",
                commandID: "test.echo",
                title: "测试命令",
                manifest: PluginManifest(
                    id: "com.padding.leap.ui-test",
                    name: "测试插件",
                    version: "1.0.0",
                    runtime: .python,
                    entry: "main.py",
                    commands: [.init(id: "test.echo", title: "测试命令")]
                ),
                pluginDirectory: URL(fileURLWithPath: "/tmp/LeapUITestPlugin"),
                iconURL: nil
            )
        ],
        paths: AppPaths(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/LeapUITestSupport"),
            resourceDirectory: URL(fileURLWithPath: "/tmp/LeapUITestResources")
        )
    )

    var body: some Scene {
        WindowGroup {
            LauncherView(model: testingModel)
                .toolbarVisibility(.hidden, for: .windowToolbar)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 98)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
