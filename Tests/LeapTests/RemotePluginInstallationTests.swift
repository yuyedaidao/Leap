import Foundation
import Testing

@testable import LeapCore

struct RemotePluginInstallationTests {
    struct Fixture {
        let root: URL
        let source: URL
        let installer: PluginInstaller

        init() throws {
            root = RemotePluginDownloaderTests.root()
            source = root.appendingPathComponent("Source")
            installer = PluginInstaller(
                paths: AppPaths(
                    applicationSupportDirectory: root.appendingPathComponent("Support"),
                    resourceDirectory: root.appendingPathComponent("Resources")
                ))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let manifest = PluginManifest(
                id: "test.remote", name: "远程测试", version: "1.0.0", runtime: .javascript,
                entry: "main.js", commands: [.init(id: "run", title: "远程测试命令")])
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
            try Data("original".utf8).write(to: source.appendingPathComponent("main.js"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        var remote: RemotePluginSource {
            .init(
                directoryURL: URL(string: "https://github.com/o/r/tree/main/plugins/a")!, owner: "o", repository: "r",
                path: "plugins/a", commit: RemotePluginDownloaderTests.commit)
        }
    }

    @Test("来源保存、同ID更新、远程始终确认，本地替换清除来源")
    func sourceAndReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        let candidate = try installer.inspect(sourceDirectory: fixture.source, source: fixture.remote)
        #expect(installer.requiresConfirmation(for: candidate))
        #expect(throws: PluginInstaller.InstallationError.confirmationRequired) {
            try installer.install(candidate, confirmed: false)
        }
        try installer.install(candidate, confirmed: true)
        #expect(try installer.readTrustRecord(for: candidate.manifest.id)?.source == fixture.remote)
        #expect(installer.requiresConfirmation(for: candidate))
        try Data("updated".utf8).write(to: fixture.source.appendingPathComponent("main.js"))
        let updated = try installer.inspect(sourceDirectory: fixture.source, source: fixture.remote)
        let destination = try installer.install(updated, confirmed: true)
        #expect(try String(contentsOf: destination.appendingPathComponent("main.js"), encoding: .utf8) == "updated")
        let local = try installer.inspect(sourceDirectory: fixture.source)
        #expect(installer.requiresConfirmation(for: local))
        try installer.install(local, confirmed: true)
        #expect(try installer.readTrustRecord(for: local.manifest.id)?.source == nil)
        #expect(!installer.requiresConfirmation(for: local))
    }

    @Test("隐藏文件的新增修改删除使新版信任失效", arguments: ["add", "change", "delete"])
    func hiddenFiles(_ operation: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if operation != "add" { try Data("old".utf8).write(to: fixture.source.appendingPathComponent(".config")) }
        let candidate = try fixture.installer.inspect(sourceDirectory: fixture.source, source: fixture.remote)
        let installed = try fixture.installer.install(candidate, confirmed: true)
        let hidden = installed.appendingPathComponent(".config")
        if operation == "delete" {
            try FileManager.default.removeItem(at: hidden)
        } else {
            try Data("new".utf8).write(to: hidden)
        }
        #expect(InstalledPluginCatalog(paths: fixture.installer.paths).loadPlugins().isEmpty)
    }

    @Test("旧记录继续使用旧摘要，不自动迁移")
    func legacyTrust() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        let candidate = try installer.inspect(sourceDirectory: fixture.source)
        let destination = try installer.install(candidate, confirmed: true)
        let digest = try installer.contentDigest(of: destination, version: 1)
        let legacy: [String: Any] = ["pluginID": candidate.manifest.id, "version": "1.0.0", "contentDigest": digest]
        let recordURL = try installer.paths.trustRecordURL(for: candidate.manifest.id)
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: recordURL)
        #expect(InstalledPluginCatalog(paths: installer.paths).loadPlugins().count == 1)
        #expect(try installer.readTrustRecord(for: candidate.manifest.id)?.digestVersion == nil)
        #expect(try Data(contentsOf: recordURL) == data)
        #expect(installer.requiresConfirmation(for: candidate))
    }

    @Test("候选确认后被修改，保留旧插件和信任")
    func candidateChanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        let candidate = try installer.inspect(sourceDirectory: fixture.source)
        let destination = try installer.install(candidate, confirmed: true)
        let record = try installer.readTrustRecord(for: candidate.manifest.id)
        try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("main.js"))
        #expect(throws: PluginInstaller.InstallationError.candidateChanged) {
            try installer.install(candidate, confirmed: true)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("main.js"), encoding: .utf8) == "original")
        #expect(try installer.readTrustRecord(for: candidate.manifest.id) == record)
    }

    @Test("目录大小写冲突不能覆盖其他插件ID")
    func identifierCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        let original = try installer.inspect(sourceDirectory: fixture.source)
        try installer.install(original, confirmed: true)
        let different = PluginManifest(
            id: "TEST.remote", name: "其他插件", version: "1", runtime: .javascript,
            entry: "main.js", commands: [.init(id: "run", title: "运行")]
        )
        try JSONEncoder().encode(different).write(to: fixture.source.appendingPathComponent("manifest.json"))
        let candidate = try installer.inspect(sourceDirectory: fixture.source)
        let destination = try installer.paths.managedPluginDirectory(for: different.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            #expect(throws: PluginInstaller.InstallationError.identifierCollision) {
                try installer.install(candidate, confirmed: true)
            }
        } else {
            try installer.install(candidate, confirmed: true)
        }
        #expect(InstalledPluginCatalog(paths: installer.paths).loadPlugins().contains { $0.id == original.manifest.id })
    }

    @Test("目录提交或信任记录写入失败均恢复旧副本", arguments: ["plugin", "trust"])
    func rollback(_ stage: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer
        let original = try installer.inspect(sourceDirectory: fixture.source)
        let destination = try installer.install(original, confirmed: true)
        let record = try installer.readTrustRecord(for: original.manifest.id)
        try Data("replacement".utf8).write(to: fixture.source.appendingPathComponent("main.js"))
        let replacement = try installer.inspect(sourceDirectory: fixture.source, source: fixture.remote)
        #expect(throws: (any Error).self) {
            try installer.install(replacement, confirmed: true, fileManager: FailingInstallFileManager(stage: stage))
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("main.js"), encoding: .utf8) == "original")
        #expect(try installer.readTrustRecord(for: original.manifest.id) == record)
        #expect(InstalledPluginCatalog(paths: installer.paths).loadPlugins().count == 1)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installer.paths.applicationSupportDirectory.path)
                .allSatisfy { !$0.hasPrefix(".install-") })
    }

    @Test("清单无效、最低版本不兼容、保留ID和符号链接拒绝安装", arguments: ["manifest", "version", "official", "symlink", "rootlink"])
    func invalidCandidate(_ kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifestURL = fixture.source.appendingPathComponent("manifest.json")
        var directory = fixture.source
        switch kind {
        case "manifest": try Data("{}".utf8).write(to: manifestURL)
        case "version", "official":
            let manifest = PluginManifest(
                id: kind == "official" ? AppPaths.templateGeneratorID : "test.remote", name: "测试", version: "1",
                runtime: .javascript,
                entry: "main.js", commands: [.init(id: "run", title: "运行")],
                minimumHostVersion: kind == "version" ? "999.0.0" : nil)
            try JSONEncoder().encode(manifest).write(to: manifestURL)
        case "rootlink":
            directory = fixture.root.appendingPathComponent("SourceAlias")
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.source)
        default:
            try FileManager.default.createSymbolicLink(
                at: fixture.source.appendingPathComponent("external"), withDestinationURL: fixture.root)
        }
        #expect(throws: (any Error).self) {
            try fixture.installer.inspect(sourceDirectory: directory, source: fixture.remote)
        }
    }
}

private final class FailingInstallFileManager: FileManager, @unchecked Sendable {
    let stage: String
    private var failed = false

    init(stage: String) {
        self.stage = stage
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if !failed
            && ((stage == "plugin" && source.lastPathComponent.hasPrefix(".staging-"))
                || (stage == "trust" && source.lastPathComponent == "pending.json"))
        {
            failed = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: source, to: destination)
    }
}
