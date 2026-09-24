import AppKit
import Foundation
import LeapCore
import Observation
import YQLogger

enum LauncherItem: Identifiable {
    case application(SystemApplicationDescriptor)
    case plugin(PluginCommandDescriptor)

    var id: String {
        switch self {
        case let .application(application): "application/\(application.id)"
        case let .plugin(command): "plugin/\(command.id)"
        }
    }

    var title: String {
        switch self {
        case let .application(application): application.name
        case let .plugin(command): command.title
        }
    }

    var subtitle: String {
        switch self {
        case let .application(application):
            application.bundleIdentifier.map { "应用 · \($0)" } ?? "应用"
        case let .plugin(command): command.pluginName
        }
    }

    var usageKey: LauncherUsageKey {
        switch self {
        case let .application(application): .application(path: application.historyKey)
        case let .plugin(command): .plugin(RecentCommandKey(pluginID: command.pluginID, commandID: command.commandID))
        }
    }

    var accessibilityID: String {
        switch self {
        case let .application(application): "launcher.application.\(application.id)"
        case let .plugin(command): "launcher.command.\(command.id)"
        }
    }
}

@MainActor
@Observable
final class LauncherModel {
    private static let logger = YQLogger(label: "com.padding.leap/launcher-model")
    enum ApplicationIndexError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "当前运行模式无法重建系统应用索引。"
            }
        }
    }

    enum InvocationState: Equatable {
        case idle
        case running(String)
        case result(String)
        case failed(String)
        case shellOutput(title: String, output: String, isRunning: Bool)
    }

    enum InvocationResponse: Sendable {
        case success(String)
        case failure(String)
    }

    private let catalog: InstalledPluginCatalog?
    let pluginPaths: AppPaths?
    private let recentStore: LauncherUsageStore
    private let scriptExecutor: PluginScriptExecutor?
    private let shellExecutor: ShellScriptExecutor?
    private let fixtureCommands: [PluginCommandDescriptor]?
    private let fixtureApplications: [SystemApplicationDescriptor]?
    private let applicationScanner: SystemApplicationScanner?
    private let applicationIndexCacheURL: URL?
    private let applicationLauncher: (URL) async throws -> Void
    private var applicationWatcher: SystemApplicationWatcher?
    private var foregroundShellTask: ShellScriptTask?

    var query = ""
    private(set) var commands: [PluginCommandDescriptor] = []
    private(set) var applications: [SystemApplicationDescriptor] = []
    private(set) var recentItems: [LauncherItem] = []
    private(set) var invocationState = InvocationState.idle
    private(set) var webCommand: PluginCommandDescriptor?
    private(set) var focusRequestID = 0
    var applicationDidLaunch: (() -> Void)?

    init(paths: AppPaths) {
        catalog = InstalledPluginCatalog(paths: paths)
        pluginPaths = paths
        recentStore = LauncherUsageStore()
        scriptExecutor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        shellExecutor = ShellScriptExecutor()
        fixtureCommands = nil
        fixtureApplications = nil
        applicationScanner = SystemApplicationScanner()
        applicationIndexCacheURL = paths.applicationIndexCacheURL
        applicationLauncher = Self.launchSystemApplication
    }

    init(
        fixtureCommands: [PluginCommandDescriptor],
        fixtureApplications: [SystemApplicationDescriptor] = [],
        paths: AppPaths? = nil,
        applicationLauncher: @escaping (URL) async throws -> Void = { _ in }
    ) {
        catalog = nil
        pluginPaths = paths
        recentStore = LauncherUsageStore(defaults: .standard, key: "uiTestingLauncherUsageRecords")
        scriptExecutor = nil
        shellExecutor = nil
        self.fixtureCommands = fixtureCommands
        self.fixtureApplications = fixtureApplications
        applicationScanner = nil
        applicationIndexCacheURL = nil
        self.applicationLauncher = applicationLauncher
        applications = fixtureApplications
    }

    var searchResults: [LauncherItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }
        let usage = Dictionary(uniqueKeysWithValues: recentStore.load(validKeys: validUsageKeys).map { ($0.key, $0) })
        let applicationMatches = applications.compactMap { application in
            application.matchRank(for: normalizedQuery).map { (LauncherItem.application(application), $0) }
        }
        let pluginMatches = commands.compactMap { command in
            pluginMatchRank(command, query: normalizedQuery).map { (LauncherItem.plugin(command), $0) }
        }
        return (applicationMatches + pluginMatches)
            .sorted { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                let leftUsage = usage[left.0.usageKey]?.lastUsed ?? .distantPast
                let rightUsage = usage[right.0.usageKey]?.lastUsed ?? .distantPast
                if leftUsage != rightUsage { return leftUsage > rightUsage }
                return left.0.title.localizedStandardCompare(right.0.title) == .orderedAscending
            }
            .prefix(8)
            .map(\.0)
    }

    func reloadPlugins() {
        commands = fixtureCommands ?? catalog?.load() ?? []
        if let fixtureApplications { applications = fixtureApplications }
        rebuildRecentItems()
    }

    var canRebuildApplicationIndex: Bool {
        applicationScanner != nil && applicationIndexCacheURL != nil
    }

    func clearRecentItems() {
        recentStore.clear()
        rebuildRecentItems()
    }

    func rebuildApplicationIndex(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let applicationIndexCacheURL else {
            completion(.failure(ApplicationIndexError.unavailable))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: applicationIndexCacheURL.path) {
                try FileManager.default.removeItem(at: applicationIndexCacheURL)
            }
        } catch {
            Self.logger.error("删除系统应用索引缓存失败：\(error.localizedDescription)。")
            completion(.failure(error))
            return
        }
        refreshApplications(completion: completion)
    }

    func startApplicationIndexing() {
        guard let applicationScanner, let applicationIndexCacheURL, applicationWatcher == nil else { return }
        applicationWatcher = SystemApplicationWatcher(roots: applicationScanner.roots) { [weak self] _, _ in
            Task { @MainActor in self?.refreshApplications() }
        }
        applicationWatcher?.start()

        Task { [weak self] in
            let cached = await Task.detached { SystemApplicationIndexCache.load(from: applicationIndexCacheURL) }.value
            guard let self, let cached else { return }
            self.applications = cached
            self.rebuildRecentItems()
        }
        refreshApplications()
    }

    func requestSearchFocus() {
        focusRequestID &+= 1
    }

    func prepareForPresentation() {
        query = ""
        invocationState = .idle
        webCommand = nil
    }

    func activateFirstSearchResult() {
        guard let first = searchResults.first else {
            return
        }
        activate(first)
    }

    func activate(_ item: LauncherItem) {
        switch item {
        case let .application(application):
            activate(application)
        case let .plugin(command):
            activate(command)
        }
    }

    func activate(_ command: PluginCommandDescriptor) {
        if command.manifest.runtime == .shell {
            activateShell(command)
            return
        }
        guard command.manifest.webEntry == nil else {
            webCommand = command
            return
        }

        invocationState = .running(command.title)
        Task { [weak self] in
            guard let self else {
                return
            }
            let response = await self.run(command, query: self.query)
            guard !Task.isCancelled else {
                return
            }
            switch response {
            case let .success(text):
                self.invocationState = .result(text)
                self.recordRecent(command)
            case let .failure(message):
                self.invocationState = .failed(message)
            }
        }
    }

    func invokeFromWeb(command: PluginCommandDescriptor, commandID: String, query: String) async -> InvocationResponse {
        guard command.manifest.commands.contains(where: { $0.id == commandID }) else {
            return .failure("网页请求了未声明的插件命令。")
        }
        let response = await run(command, commandID: commandID, query: query)
        if case .success = response {
            recordRecent(command)
        }
        return response
    }

    func dismissWebPlugin() {
        webCommand = nil
    }

    private func run(_ command: PluginCommandDescriptor, query: String) async -> InvocationResponse {
        await run(command, commandID: command.commandID, query: query)
    }

    private func run(_ command: PluginCommandDescriptor, commandID: String, query: String) async -> InvocationResponse {
        guard let scriptExecutor else {
            return .failure("测试模式不执行插件脚本。")
        }
        return await Task.detached(priority: .userInitiated) {
            do {
                return .success(try scriptExecutor.invoke(
                    manifest: command.manifest,
                    pluginDirectory: command.pluginDirectory,
                    commandID: commandID,
                    query: query
                ))
            } catch {
                YQLogger(label: "com.padding.leap/launcher-model")
                    .error("插件调用失败：\(error.localizedDescription)。")
                return .failure(error.localizedDescription)
            }
        }.value
    }

    private func recordRecent(_ command: PluginCommandDescriptor) {
        recentStore.record(.plugin(RecentCommandKey(pluginID: command.pluginID, commandID: command.commandID)), validKeys: validUsageKeys)
        rebuildRecentItems()
    }

    private func activate(_ application: SystemApplicationDescriptor) {
        invocationState = .running(application.name)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await applicationLauncher(application.url)
                guard !Task.isCancelled else { return }
                recentStore.record(.application(path: application.historyKey), validKeys: validUsageKeys)
                rebuildRecentItems()
                applicationDidLaunch?()
            } catch {
                Self.logger.error("启动应用失败：\(application.name)，\(error.localizedDescription)。")
                invocationState = .failed("无法启动 \(application.name)：\(error.localizedDescription)")
            }
        }
    }

    private func refreshApplications(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard let applicationScanner, let applicationIndexCacheURL else {
            completion(.failure(ApplicationIndexError.unavailable))
            return
        }
        Task { [weak self] in
            let indexed = await Task.detached { applicationScanner.scan() }.value
            guard let self else { return }
            applications = indexed
            rebuildRecentItems()
            do {
                try SystemApplicationIndexCache.save(indexed, to: applicationIndexCacheURL)
                completion(.success(()))
            } catch {
                Self.logger.error("保存系统应用索引失败：\(error.localizedDescription)。")
                completion(.failure(error))
            }
        }
    }

    private var validUsageKeys: Set<LauncherUsageKey> {
        Set(applications.map { .application(path: $0.historyKey) })
            .union(commands.map { .plugin(RecentCommandKey(pluginID: $0.pluginID, commandID: $0.commandID)) })
    }

    private func rebuildRecentItems() {
        let items = Dictionary(uniqueKeysWithValues: (applications.map(LauncherItem.application) + commands.map(LauncherItem.plugin)).map { ($0.usageKey, $0) })
        recentItems = recentStore.load(validKeys: Set(items.keys)).compactMap { items[$0.key] }
    }

    private func pluginMatchRank(_ command: PluginCommandDescriptor, query: String) -> Int? {
        let query = SystemApplicationDescriptor.normalize(query)
        let title = SystemApplicationDescriptor.normalize(command.title)
        let pluginName = SystemApplicationDescriptor.normalize(command.pluginName)
        let commandID = SystemApplicationDescriptor.normalize(command.commandID)
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if pluginName.hasPrefix(query) || commandID.hasPrefix(query) { return 3 }
        if pluginName.contains(query) || commandID.contains(query) { return 4 }
        return nil
    }

    private static func launchSystemApplication(at url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

extension LauncherModel {
    func stopForegroundShell() {
        foregroundShellTask?.cancel()
    }

    private func activateShell(_ command: PluginCommandDescriptor) {
        guard let shellExecutor else {
            invocationState = .failed("测试模式不执行 Shell 脚本。")
            return
        }
        guard let manifestCommand = command.manifest.commands.first(where: { $0.id == command.commandID }) else {
            invocationState = .failed("Shell 插件命令未在清单中声明。")
            return
        }

        let entryURL = command.pluginDirectory.appendingPathComponent(command.manifest.entry)
        switch manifestCommand.resolvedExecutionMode {
        case .background:
            do {
                try shellExecutor.startBackground(
                    entryURL: entryURL,
                    pluginDirectory: command.pluginDirectory,
                    commandID: command.commandID
                )
                recordRecent(command)
                invocationState = .idle
                applicationDidLaunch?()
            } catch {
                Self.logger.error("后台 Shell 脚本启动失败：\(error.localizedDescription)。")
                invocationState = .failed(error.localizedDescription)
            }
        case .foreground:
            do {
                let task = try shellExecutor.makeForegroundTask(
                    entryURL: entryURL,
                    pluginDirectory: command.pluginDirectory,
                    commandID: command.commandID
                )
                let outputHandler: @Sendable (String) -> Void = { [weak self] output in
                    Task { @MainActor [weak self] in
                        self?.appendForegroundShellOutput(output)
                    }
                }
                foregroundShellTask = task
                invocationState = .shellOutput(title: command.title, output: "", isRunning: true)
                try task.start(onOutput: outputHandler)

                Task { [weak self, task] in
                    let result = await Task.detached(priority: .userInitiated) {
                        Result { try task.waitForCompletion(onOutput: outputHandler) }
                    }.value
                    guard let self, self.foregroundShellTask === task else { return }
                    self.foregroundShellTask = nil
                    self.finishForegroundShell(title: command.title, result: result)
                    if case .success = result {
                        self.recordRecent(command)
                    }
                }
            } catch {
                Self.logger.error("前台 Shell 脚本启动失败：\(error.localizedDescription)。")
                invocationState = .failed(error.localizedDescription)
            }
        }
    }

    private func appendForegroundShellOutput(_ output: String) {
        guard case let .shellOutput(title, currentOutput, true) = invocationState else { return }
        invocationState = .shellOutput(
            title: title,
            output: limitedShellOutput(currentOutput + output),
            isRunning: true
        )
    }

    private func finishForegroundShell(title: String, result: Result<Void, Error>) {
        let currentOutput: String
        if case let .shellOutput(_, output, _) = invocationState {
            currentOutput = output
        } else {
            currentOutput = ""
        }
        let finalOutput: String
        switch result {
        case .success:
            finalOutput = currentOutput.isEmpty ? "执行完成。" : currentOutput
        case let .failure(error):
            Self.logger.error("前台 Shell 脚本失败：\(error.localizedDescription)。")
            finalOutput = limitedShellOutput(currentOutput + "\n\(error.localizedDescription)\n")
        }
        invocationState = .shellOutput(title: title, output: finalOutput, isRunning: false)
    }

    private func limitedShellOutput(_ output: String) -> String {
        let limit = 64 * 1024
        guard output.utf8.count > limit else { return output }
        let prefix = "…输出已截断，以下为最新内容：\n"
        let suffix = output.utf8.suffix(limit - prefix.utf8.count)
        return prefix + String(decoding: suffix, as: UTF8.self)
    }
}
