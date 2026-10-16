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
            PluginInstallationModel(paths: fixture.installer.paths, downloader: downloader, didInstall: didInstall),
            mock, temporary
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }

    @Test("远程准备、确认与刷新，重复提交和重复确认不产生额外安装")
    func installAndRefresh() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        // 先安装本地版本，以验证替换确认中会显示来源变化。
        try fixture.installer.install(fixture.installer.inspect(sourceDirectory: fixture.source), confirmed: true)
        var refreshes = 0
        let (model, mock, temporary) = try makeModel(fixture: fixture) { refreshes += 1 }
        model.presentRemoteInstallation()
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
        #expect(model.plugins.contains { $0.id == "test.remote" })
        #expect(
            try fixture.installer.readTrustRecord(for: "test.remote")?.source?.commit
                == RemotePluginDownloaderTests.commit)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
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

    @Test("错误后可重试，失效清单和安装失败不增加信任")
    func failureAndRetry() async throws {
        let fixture = try RemotePluginInstallationTests.Fixture()
        defer { fixture.remove() }
        let (model, _, _) = try makeModel(fixture: fixture)
        model.presentRemoteInstallation()
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
        #expect(try fixture.installer.readTrustRecord(for: "test.remote") == nil)
        model.downloadRemote(address: address)
        try await waitUntil { model.candidate != nil }
        #expect(model.errorMessage == nil)
        model.rejectInstallation()
    }
}
