import Foundation
import Testing
@testable import LeapCore

struct OfficialPluginTests {
    private func fixture() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapOfficial-\(UUID().uuidString)")
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
        return (paths, root)
    }

    @Test("全新用户目录直接加载官方插件，无需安装或信任记录")
    func freshInstallation() throws {
        let (paths, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = InstalledPluginCatalog(paths: paths)
        let plugins = catalog.loadPlugins()
        #expect(Set(plugins.map(\.id)) == [AppPaths.templateGeneratorID, AppPaths.clipboardPluginID])
        #expect(plugins.allSatisfy { $0.origin == .official })
        #expect(Set(catalog.load().map(\.commandID)) == ["template.generate", "clipboard.history"])
        #expect(!FileManager.default.fileExists(atPath: paths.applicationSupportDirectory.path))
    }

    @Test("拒绝本地覆盖和卸载官方ID，包括跳过检查的安装候选")
    func reservedIdentity() throws {
        let (paths, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = paths.officialPluginsDirectory.appendingPathComponent("TemplateGenerator")
        let manifest = try PluginManifestValidator().load(from: directory)
        let installer = PluginInstaller(paths: paths)
        #expect(throws: PluginInstaller.InstallationError.officialPluginReserved) {
            try installer.inspect(sourceDirectory: directory)
        }
        let candidate = PluginInstallCandidate(sourceDirectory: directory, manifest: manifest, contentDigest: "unused")
        #expect(throws: PluginInstaller.InstallationError.officialPluginReserved) {
            try installer.install(candidate, confirmed: true)
        }
        #expect(throws: PluginInstaller.InstallationError.officialPluginReserved) {
            try installer.uninstall(pluginID: manifest.id)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: PluginInstaller.InstallationError.officialPluginReserved) {
            try installer.inspect(sourceDirectory: paths.officialPluginsDirectory.appendingPathComponent("Clipboard"))
        }
    }

    @Test("旧同ID受管副本去重保留；官方损坏不回退，其他本地插件继续可用")
    func legacyDuplicateAndInvalidBundle() throws {
        let (paths, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PluginInstaller(paths: paths)
        let directory = paths.officialPluginsDirectory.appendingPathComponent("TemplateGenerator")
        let manifest = try PluginManifestValidator().load(from: directory)
        try paths.createManagedDirectories()
        let legacy = try paths.managedPluginDirectory(for: manifest.id)
        try FileManager.default.copyItem(at: directory, to: legacy)
        let record = PluginTrustRecord(pluginID: manifest.id, version: manifest.version,
                                      contentDigest: try installer.contentDigest(of: legacy))
        try JSONEncoder().encode(record).write(to: paths.trustRecordURL(for: manifest.id))
        let local = root.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "printf hello".write(to: local.appendingPathComponent("main.zsh"), atomically: true, encoding: .utf8)
        let localManifest = PluginManifest(id: "test.local", name: "本地", version: "1.0.0", runtime: .shell,
                                           entry: "main.zsh", commands: [.init(id: "local.run", title: "本地")])
        try JSONEncoder().encode(localManifest).write(to: local.appendingPathComponent("manifest.json"))
        try installer.install(installer.inspect(sourceDirectory: local), confirmed: true)
        let catalog = InstalledPluginCatalog(paths: paths)
        #expect(catalog.loadPlugins().filter { $0.id == manifest.id }.count == 1)
        #expect(catalog.loadPlugins().first { $0.id == "test.local" }?.origin == .local)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("main.js"))
        #expect(Set(catalog.loadPlugins().map(\.id)) == ["test.local", AppPaths.clipboardPluginID])
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: try paths.trustRecordURL(for: manifest.id).path))
        try installer.uninstall(pluginID: localManifest.id)
        #expect(catalog.loadPlugins().map(\.id) == [AppPaths.clipboardPluginID])
        #expect(FileManager.default.fileExists(atPath: local.path))
    }
}
