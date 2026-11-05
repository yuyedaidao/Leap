import Foundation
import Testing

@testable import LeapCore

struct PluginEnabledStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LeapPluginEnabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("默认全部启用，禁用后持久化到同一 UserDefaults，重新启用清除记录")
    func persistence() {
        let defaults = makeDefaults()
        let store = PluginEnabledStore(defaults: defaults)
        #expect(store.isEnabled(pluginID: "test.a"))
        #expect(store.disabledPluginIDs.isEmpty)

        store.setEnabled(false, pluginID: "test.a")
        #expect(!store.isEnabled(pluginID: "test.a"))
        #expect(PluginEnabledStore(defaults: defaults).disabledPluginIDs == ["test.a"])

        store.setEnabled(true, pluginID: "test.a")
        #expect(PluginEnabledStore(defaults: defaults).disabledPluginIDs.isEmpty)
    }

    @Test("启动器索引剔除禁用插件，设置页列表仍保留官方与本地插件")
    func catalogFiltering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapEnabled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            resourceDirectory: root.appendingPathComponent("Resources")
        )
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: paths.resourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: project.appendingPathComponent("Resources/Leap/OfficialPlugins"),
            to: paths.officialPluginsDirectory
        )

        let installer = PluginInstaller(paths: paths)
        let source = root.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "printf hello".write(
            to: source.appendingPathComponent("main.zsh"), atomically: true, encoding: .utf8
        )
        let localManifest = PluginManifest(
            id: "test.local", name: "本地", version: "1.0.0", runtime: .shell,
            entry: "main.zsh", commands: [.init(id: "local.run", title: "本地")]
        )
        try JSONEncoder().encode(localManifest).write(to: source.appendingPathComponent("manifest.json"))
        try installer.install(installer.inspect(sourceDirectory: source), confirmed: true)

        let store = PluginEnabledStore(defaults: makeDefaults())
        let catalog = InstalledPluginCatalog(paths: paths, enabledStore: store)
        let officialID = AppPaths.templateGeneratorID
        #expect(catalog.load().contains { $0.pluginID == officialID })
        #expect(catalog.load().contains { $0.pluginID == "test.local" })

        store.setEnabled(false, pluginID: officialID)
        store.setEnabled(false, pluginID: "test.local")
        let remaining = catalog.load()
        #expect(!remaining.contains { $0.pluginID == officialID || $0.pluginID == "test.local" })
        // 设置页依赖 loadPlugins 看到禁用项才能重新启用。
        #expect(catalog.loadPlugins().contains { $0.id == officialID })
        #expect(catalog.loadPlugins().contains { $0.id == "test.local" })

        store.setEnabled(true, pluginID: officialID)
        #expect(catalog.load().contains { $0.pluginID == officialID })
        #expect(!catalog.load().contains { $0.pluginID == "test.local" })
    }

    @Test("设置页切换开关写入 store、刷新状态并触发启动器刷新")
    @MainActor
    func modelToggle() throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        try installer.install(installer.inspect(sourceDirectory: fixture.source), confirmed: true)

        let store = PluginEnabledStore(defaults: makeDefaults())
        var refreshes = 0
        let model = PluginInstallationModel(paths: installer.paths, enabledStore: store) { refreshes += 1 }
        let plugin = try #require(model.plugins.first { $0.id == "test.remote" })
        #expect(model.isEnabled(plugin))

        model.setEnabled(false, for: plugin)
        #expect(!model.isEnabled(plugin))
        #expect(store.disabledPluginIDs == ["test.remote"])
        #expect(refreshes == 1)

        model.setEnabled(true, for: plugin)
        #expect(model.isEnabled(plugin))
        #expect(refreshes == 2)

        // 卸载后不残留禁用记录，重装同一插件应默认启用。
        model.setEnabled(false, for: plugin)
        model.uninstall(plugin)
        #expect(store.isEnabled(pluginID: "test.remote"))
    }
}
