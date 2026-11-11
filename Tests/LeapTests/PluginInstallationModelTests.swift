import Foundation
import Testing

@testable import LeapCore

@MainActor
struct PluginInstallationModelTests {
    private let address = "https://github.com/o/r/tree/main/plugins/a"

    private func makeModel(
        fixture: RemotePluginInstallationTests.Fixture,
        delay: Duration = .milliseconds(1),
        didInstall: @escaping () -> Void = {}
    ) throws -> (PluginInstallationModel, GitHubFixtureClient, URL) {
        let files = try ["manifest.json", "main.js"].reduce(into: [String: Data]()) {
            $0[$1] = try Data(contentsOf: fixture.source.appendingPathComponent($1))
        }
        let mock = GitHubFixtureClient(replies: try RemotePluginDownloaderTests.fixtures(files: files), delay: delay)
        let temporary = fixture.root.appendingPathComponent("Downloads")
        let downloader = RemotePluginDownloader(client: mock, temporaryDirectory: temporary)
        return (
            PluginInstallationModel(
                paths: fixture.installer.paths, enabledStore: PluginEnabledStore(key: fixture.root.lastPathComponent),
                downloader: downloader, didInstall: didInstall
            ),
            mock, temporary
        )
    }

    @Test("即使本地来源内容相同，定向更新也要求确认")
    func unchangedLocalUpdateRequiresConfirmation() throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let original = try fixture.installer.inspect(sourceDirectory: fixture.source)
        try fixture.installer.install(original, confirmed: true)
        let (model, _, _) = try makeModel(fixture: fixture)

        model.inspect(directory: fixture.source, isSecurityScoped: false, updating: original.manifest.id)
        #expect(model.isConfirmationPresented)
        model.rejectInstallation()
        #expect(!model.isUpdating)
        #expect(model.candidate == nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }

    @Test("定向远程更新刷新插件并保留禁用状态，重复提交和确认只安装一次")
    func installAndRefresh() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        // 先安装本地版本，以验证替换确认中会显示来源变化。
        try fixture.installer.install(fixture.installer.inspect(sourceDirectory: fixture.source), confirmed: true)
        var refreshes = 0
        let (model, mock, temporary) = try makeModel(fixture: fixture) { refreshes += 1 }
        let previous = try #require(model.plugins.first { $0.id == "test.remote" })
        model.setEnabled(false, for: previous)
        defer { model.setEnabled(true, for: previous) }
        refreshes = 0
        try Data("updated".utf8).write(to: fixture.source.appendingPathComponent("main.js"))
        model.presentRemoteInstallation(updating: previous.id)
        #expect(model.remoteInitialAddress.isEmpty)
        model.downloadRemote(address: address)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        #expect(model.isRemotePresented)
        #expect(!model.isPreparing)
        #expect(model.replacementMessage?.contains("来源发生变化") == true)
        #expect(model.progress?.completedFiles == 2)
        #expect((await mock.requests).filter { $0.host == "raw.githubusercontent.com" }.count == 2)
        model.confirmInstallation()
        model.confirmInstallation()
        try await waitUntil { !model.isInstalling }
        #expect(refreshes == 1)
        #expect(!model.isRemotePresented)
        #expect(model.candidate == nil)
        #expect(!model.isUpdating)
        let updated = try #require(model.plugins.first { $0.id == previous.id })
        #expect(!model.isEnabled(updated))
        #expect(
            try fixture.installer.readTrustRecord(for: "test.remote")?.source?.commit
                == RemotePluginDownloaderTests.commit)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        model.presentRemoteInstallation(updating: updated.id)
        #expect(model.remoteInitialAddress == address)
        #expect(!model.isPreparing)
        model.rejectInstallation()
    }

    @Test("本地和远程更新拒绝其他插件，取消后可用普通安装")
    func mismatchedUpdateTarget() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let original = try fixture.installer.inspect(sourceDirectory: fixture.source)
        let installed = try fixture.installer.install(original, confirmed: true)
        let originalRecord = try fixture.installer.readTrustRecord(for: original.manifest.id)
        let other = PluginManifest(
            id: "test.other", name: "其他插件", version: "1.0.0", runtime: .javascript,
            entry: "main.js", commands: [.init(id: "run", title: "运行")]
        )
        try JSONEncoder().encode(other).write(to: fixture.source.appendingPathComponent("manifest.json"))
        let (model, _, temporary) = try makeModel(fixture: fixture)

        model.inspect(directory: fixture.source, isSecurityScoped: false, updating: original.manifest.id)
        #expect(model.candidate == nil)
        #expect(model.errorMessage?.contains("不一致") == true)
        #expect(!model.isConfirmationPresented)
        #expect(!model.isUpdating)

        model.presentRemoteInstallation(updating: original.manifest.id)
        model.downloadRemote(address: address)
        try await waitUntil { !model.isPreparing }
        #expect(model.candidate == nil)
        #expect(model.errorMessage?.contains("不一致") == true)
        #expect(model.isUpdating)
        #expect(model.isRemotePresented)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        #expect(try fixture.installer.readTrustRecord(for: original.manifest.id) == originalRecord)
        #expect(try fixture.installer.inspect(sourceDirectory: installed).manifest == original.manifest)
        #expect(try fixture.installer.readTrustRecord(for: other.id) == nil)

        model.rejectInstallation()
        model.presentRemoteInstallation()
        #expect(!model.isUpdating)
        #expect(model.remoteInitialAddress.isEmpty)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        #expect(model.candidate?.manifest.id == other.id)
        model.confirmInstallation()
        try await waitUntil { !model.isInstalling }
        #expect(try fixture.installer.readTrustRecord(for: other.id)?.source != nil)
    }

    @Test("拒绝准备完成的候选清理下载，保留旧插件和信任")
    func rejectCandidate() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        try fixture.installer.install(fixture.installer.inspect(sourceDirectory: fixture.source), confirmed: true)
        let record = try fixture.installer.readTrustRecord(for: "test.remote")
        let (model, _, temporary) = try makeModel(fixture: fixture)
        model.presentRemoteInstallation()
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        model.rejectInstallation()
        #expect(model.candidate == nil)
        #expect(model.plugins.count == 1)
        #expect(try fixture.installer.readTrustRecord(for: "test.remote") == record)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test("下载期间取消并开始新请求，旧回调不覆盖新候选")
    func cancellationAndRestart() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let (model, mock, temporary) = try makeModel(fixture: fixture, delay: .milliseconds(150))
        model.presentRemoteInstallation()
        model.downloadRemote(address: address)
        while !(await mock.requests).contains(where: { $0.host == "raw.githubusercontent.com" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.rejectInstallation()
        #expect(!model.isPreparing)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        #expect(model.errorMessage == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).count == 1)
        model.rejectInstallation()
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test("商店安装直接打开弹窗，完成后刷新插件并清空商店标记")
    func storeInstall() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        var refreshes = 0
        let (model, _, temporary) = try makeModel(fixture: fixture) { refreshes += 1 }
        refreshes = 0

        model.installFromStore(address: address, pluginID: "test.remote", pluginName: "测试插件")
        #expect(model.isRemotePresented)
        #expect(model.storeInstallName == "测试插件")
        #expect(!model.isUpdating)
        try await waitUntil { model.candidate != nil }
        #expect(model.candidate?.manifest.id == "test.remote")

        model.confirmInstallation()
        try await waitUntil { !model.isInstalling }
        #expect(refreshes == 1)
        #expect(!model.isRemotePresented)
        #expect(model.storeInstallName == nil)
        #expect(model.plugins.contains { $0.id == "test.remote" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)

        // 安装失败时弹窗仍在，商店标记必须保留，否则地址表单会重新冒出来。
        model.installFromStore(address: address, pluginID: "test.remote", pluginName: "测试插件")
        try await waitUntil { model.candidate != nil }
        let failedCandidate = try #require(model.candidate)
        try Data("changed after confirmation".utf8).write(
            to: failedCandidate.sourceDirectory.appendingPathComponent("main.js"))
        model.confirmInstallation()
        try await waitUntil { !model.isInstalling }
        #expect(model.errorMessage?.contains("发生变化") == true)
        #expect(model.isRemotePresented)
        #expect(model.storeInstallName == "测试插件")

        // 取消也要清掉商店标记，否则下一次远程安装会被当成商店流程隐藏地址表单。
        model.installFromStore(address: address, pluginID: "test.remote", pluginName: "测试插件")
        model.rejectInstallation()
        #expect(model.storeInstallName == nil)
    }

    @Test("远程更新失败后可重试，保留旧副本和信任")
    func failureAndRetry() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let original = try fixture.installer.inspect(sourceDirectory: fixture.source, source: fixture.remote)
        let installed = try fixture.installer.install(original, confirmed: true)
        let originalRecord = try fixture.installer.readTrustRecord(for: original.manifest.id)
        let (model, _, _) = try makeModel(fixture: fixture)
        model.presentRemoteInstallation(updating: original.manifest.id)
        model.downloadRemote(address: "https://github.com/o/r")
        try await waitUntil { !model.isPreparing }
        #expect(model.errorMessage != nil)
        #expect(model.candidate == nil)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        let candidate = try #require(model.candidate)
        try Data("changed after confirmation".utf8).write(
            to: candidate.sourceDirectory.appendingPathComponent("main.js"))
        model.confirmInstallation()
        try await waitUntil { !model.isInstalling }
        #expect(model.errorMessage?.contains("发生变化") == true)
        #expect(model.remotePhase == nil)
        #expect(model.candidate == nil)
        #expect(try fixture.installer.readTrustRecord(for: original.manifest.id) == originalRecord)
        #expect(try fixture.installer.contentDigest(of: installed) == original.contentDigest)
        #expect(model.isUpdating)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        #expect(model.errorMessage == nil)
        model.rejectInstallation()
    }
}
