import Foundation
import Testing
@testable import LeapCore

@MainActor
struct PluginDirectorySessionTests {
    @Test("重复选择不会打开第二个原生对话框")
    func duplicateSelection() async throws {
        let started = AsyncStream<Void>.makeStream()
        var resumeChoice: CheckedContinuation<URL?, Never>?
        let session = PluginDirectorySession(choose: {
            await withCheckedContinuation { continuation in
                resumeChoice = continuation
                started.continuation.yield(())
                started.continuation.finish()
            }
        }, open: { _ in true })
        let first = Task { try await session.chooseDirectory() }
        for await _ in started.stream { }
        await #expect(throws: PluginDirectorySession.DirectoryError.selectionInProgress) {
            _ = try await session.chooseDirectory()
        }
        resumeChoice?.resume(returning: nil)
        #expect(try await first.value == nil)
    }

    @Test("目录接口只接受当前插件主页面")
    func pageAuthorization() {
        let page = URL(fileURLWithPath: "/tmp/plugin/index.html")
        #expect(PluginDirectorySession.isAllowedPage(page, mainFrame: true, expectedPage: page))
        #expect(!PluginDirectorySession.isAllowedPage(page, mainFrame: false, expectedPage: page))
        #expect(!PluginDirectorySession.isAllowedPage(nil, mainFrame: true, expectedPage: page))
        #expect(!PluginDirectorySession.isAllowedPage(
            URL(string: "https://example.com/index.html"), mainFrame: true, expectedPage: page
        ))
        #expect(!PluginDirectorySession.isAllowedPage(
            page.deletingLastPathComponent().appendingPathComponent("other.html"), mainFrame: true, expectedPage: page
        ))
    }

    @Test("选择目录、取消以及 Finder 失败保持清晰状态")
    func selectionAndOpenFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeapDirectory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var choice: URL? = directory
        var opened: URL?
        let session = PluginDirectorySession(choose: { choice }, open: { opened = $0; return false })
        #expect(try await session.chooseDirectory() == directory.resolvingSymlinksInPath().path)
        choice = nil
        #expect(try await session.chooseDirectory() == nil)
        #expect(throws: PluginDirectorySession.DirectoryError.openFailed) {
            try session.openDirectory(path: directory.path)
        }
        #expect(opened == directory.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("目录授权允许子目录，拒绝同名前缀和符号链接越界")
    func containment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapBoundary-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("parent")
        let child = parent.appendingPathComponent("child")
        let outside = root.appendingPathComponent("parent-other")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("escape"), withDestinationURL: outside
        )
        var opened: URL?
        let session = PluginDirectorySession(choose: { parent }, open: { opened = $0; return true })
        #expect(throws: PluginDirectorySession.DirectoryError.outsideSelection) {
            try session.openDirectory(path: child.path)
        }
        _ = try await session.chooseDirectory()
        try session.openDirectory(path: child.path)
        #expect(opened == child.resolvingSymlinksInPath().standardizedFileURL)
        for path in [outside.path, parent.appendingPathComponent("escape").path] {
            #expect(throws: PluginDirectorySession.DirectoryError.outsideSelection) {
                try session.openDirectory(path: path)
            }
        }
        for path in ["relative", "", "\0"] {
            #expect(throws: PluginDirectorySession.DirectoryError.invalidDirectory) {
                try session.openDirectory(path: path)
            }
        }
        #expect(throws: PluginDirectorySession.DirectoryError.invalidDirectory) {
            try session.openDirectory(path: parent.appendingPathComponent("missing").path)
        }
    }

    @Test("无效选择被拒绝，更换保存位置撤销旧授权")
    func selectionReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeapSelection-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var choice = first
        let session = PluginDirectorySession(choose: { choice }, open: { _ in true })
        _ = try await session.chooseDirectory()
        choice = second
        _ = try await session.chooseDirectory()
        #expect(throws: PluginDirectorySession.DirectoryError.outsideSelection) {
            try session.openDirectory(path: first.path)
        }
        choice = root.appendingPathComponent("missing")
        await #expect(throws: PluginDirectorySession.DirectoryError.invalidDirectory) {
            _ = try await session.chooseDirectory()
        }
    }
}
