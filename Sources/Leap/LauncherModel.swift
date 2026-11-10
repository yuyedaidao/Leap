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
    let hostAPI: PluginHostAPI?
    private let clipboardMonitor: ClipboardHistoryMonitor?
    var externalTargetPID: Int32?
    var inputWindowVisibility: ((Bool) -> Void)?
    private let recentStore: LauncherUsageStore
    private let scriptExecutor: PluginScriptExecutor?
    private let shellExecutor: ShellScriptExecutor?
    private let fixtureCommands: [PluginCommandDescriptor]?
    private let fixtureApplications: [SystemApplicationDescriptor]?
    private let applicationScanner: SystemApplicationScanner?
    private let applicationIndexCacheURL: URL?
    private let applicationLauncher: (URL) async throws -> Void
    private var applicationWatcher: SystemApplicationWatcher?
    private var actionSession: PluginScriptSession?
    private var actionID: UUID?
    private var invocationRevision = 0
    private var pendingPluginRun: (command: PluginCommandDescriptor, query: String)?
    private var foregroundShellTask: ShellScriptTask?
    private var commandMatchers: [String: PluginCommandMatcher] = [:]

    var query = ""
    var selectedSearchResultID: LauncherItem.ID?
    private(set) var commands: [PluginCommandDescriptor] = []
    private(set) var applications: [SystemApplicationDescriptor] = []
    private(set) var recentItems: [LauncherItem] = []
    private(set) var invocationState = InvocationState.idle
    /// 前台 Shell 运行视图所属的命令；仅用于头部标签展示。
    private(set) var shellRunCommand: PluginCommandDescriptor?
    private(set) var webCommand: PluginCommandDescriptor?
    private(set) var interaction: PluginInteractionSession?
    private(set) var focusRequestID = 0
    var applicationDidLaunch: (() -> Void)?
    var hideRequested: (() -> Void)?
    var webPluginRequested: ((PluginCommandDescriptor) -> Void)?
    /// 跨插件调用登记的启动请求；由面板在调用方收到回复后执行。
    var pluginRunRequested: ((PluginCommandDescriptor, String) -> Void)?

    init(paths: AppPaths) {
        catalog = InstalledPluginCatalog(paths: paths)
        pluginPaths = paths
        let hostAPI = PluginHostAPI(paths: paths)
        self.hostAPI = hostAPI
        let monitor = try? ClipboardHistoryMonitor(paths: paths, documentStores: hostAPI.documentStores)
        clipboardMonitor = monitor
        hostAPI.onClipboardWrite = { [weak monitor] in monitor?.suppressNextCapture() }
        monitor?.start()
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
        hostAPI = paths.map { PluginHostAPI(paths: $0) }
        clipboardMonitor = nil
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
        commandMatchers = Dictionary(uniqueKeysWithValues: commands.map { command in
            (command.id, PluginCommandMatcher(command: configuration(for: command), pluginName: command.pluginName))
        })
        if let interaction, !commands.contains(where: { $0 == interaction.command }) { exitInteraction() }
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

    func activateFirstSearchResult() {
        guard let first = searchResults.first else {
            return
        }
        activate(first)
    }

    func activateListShortcut(at index: Int, isRepeat: Bool) -> Bool {
        if let interaction { return interaction.list?.select(at: index, isRepeat: isRepeat) ?? false }
        // 前台 Shell 运行视图没有列表，数字快捷键不能操作已隐藏的搜索结果。
        guard !showsShellRun else { return false }
        let results = searchResults
        guard results.indices.contains(index) else { return false }
        if isRepeat { return true }
        switch invocationState {
        case .running, .shellOutput(_, _, true): return true
        default: break
        }
        selectedSearchResultID = results[index].id
        activate(results[index])
        return true
    }

    func activate(_ item: LauncherItem) {
        switch item {
        case let .application(application):
            activate(application)
        case let .plugin(command):
            activate(command)
        }
    }

    func activate(_ command: PluginCommandDescriptor, query overrideQuery: String? = nil) {
        invocationRevision &+= 1
        closeActionSession()
        let configuration = configuration(for: command)
        let launchQuery = overrideQuery ?? query
        if configuration.mode == .interactive {
            exitInteraction()
            let initialInput = overrideQuery ?? (keywordMatchRank(command, query: query) == nil &&
                commandMatchers[command.id]?.matchesContent(query) == true ? query : "")
            interaction = PluginInteractionSession(
                command: command, configuration: configuration,
                previousSearch: query, initialInput: initialInput, executor: scriptExecutor,
                hostAPI: hostAPI, targetPID: externalTargetPID, inputWindowVisibility: inputWindowVisibility
            )
            interaction?.hostAction = { [weak self] method in
                if method == "outPlugin" { self?.exitInteraction() }
                else if method == "hideMainWindow" || PluginHostAPI.inputMethods.contains(method) { self?.exitInteraction(); self?.hideRequested?() }
            }
            interaction?.onPluginRun = { [weak self] in self?.activatePendingPluginRun() }
            invocationState = .idle
            recordRecent(command)
            if configuration.inputEnabled { requestSearchFocus() }
            Self.logger.debug("已进入交互插件：\(command.id)。")
            return
        }
        if command.manifest.runtime == .shell {
            activateShell(command)
            return
        }
        guard configuration.mode == .action || command.manifest.webEntry == nil else {
            webCommand = command
            // 与内嵌交互插件一致，打开窗口即记录使用，无需等待网页调用脚本。
            recordRecent(command)
            webPluginRequested?(command)
            return
        }

        invocationState = .running(command.title)
        let revision = invocationRevision
        Task { [weak self] in
            guard let self else {
                return
            }
            let response = await self.run(command, query: launchQuery)
            guard !Task.isCancelled, self.invocationRevision == revision else {
                return
            }
            switch response {
            case let .success(text):
                self.invocationState = text.isEmpty ? .idle : .result(text)
                self.recordRecent(command)
            case let .failure(message):
                self.invocationState = .failed(message)
            }
        }
    }

    func makeWebSession(_ command: PluginCommandDescriptor) -> PluginInteractionSession {
        let session = PluginInteractionSession(
            command: command,
            configuration: .init(id: command.commandID, title: command.title, mode: .interactive,
                                 presentation: .web, input: .init(enabled: false)),
            previousSearch: query, initialInput: "", executor: scriptExecutor,
            hostAPI: hostAPI, targetPID: externalTargetPID, inputWindowVisibility: inputWindowVisibility
        )
        session.onPluginRun = { [weak self] in self?.activatePendingPluginRun() }
        return session
    }

    /// 只校验并登记目标命令，真正的启动交给回复后的 `activatePendingPluginRun`，否则调用方会收不到回复。
    func preparePluginRun(pluginID: String, commandID: String, query: String) -> Bool {
        guard let command = commands.first(where: { $0.pluginID == pluginID && $0.commandID == commandID }) else {
            return false
        }
        pendingPluginRun = (command, query)
        return true
    }

    func activatePendingPluginRun() {
        guard let pending = pendingPluginRun else { return }
        pendingPluginRun = nil
        pluginRunRequested?(pending.command, pending.query)
    }

    func dismissWebPlugin() {
        webCommand = nil
    }

    func exitInteraction() {
        guard let interaction else { return }
        interaction.close()
        query = interaction.previousSearch
        self.interaction = nil
        invocationState = .idle
        requestSearchFocus()
        Self.logger.debug("已退出交互插件：\(interaction.command.id)。")
    }

    private func configuration(for command: PluginCommandDescriptor) -> PluginManifest.Command {
        command.manifest.commands.first(where: { $0.id == command.commandID }) ??
            .init(id: command.commandID, title: command.title)
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
        keywordMatchRank(command, query: query) ??
            (commandMatchers[command.id]?.matchesContent(self.query) == true ? SearchMatchRank.content.rawValue : nil)
    }

    private func keywordMatchRank(_ command: PluginCommandDescriptor, query: String) -> Int? {
        commandMatchers[command.id]?.keywordMatchRank(for: query)
    }

    private static func launchSystemApplication(at url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// 动作插件会话与 Shell 执行分别组织，生命周期仍由 LauncherModel 协调。
extension LauncherModel {
    private func run(_ command: PluginCommandDescriptor, query: String) async -> InvocationResponse {
        await run(command, commandID: command.commandID, query: query)
    }

    private func run(_ command: PluginCommandDescriptor, commandID: String, query: String) async -> InvocationResponse {
        guard let scriptExecutor else {
            return .failure("测试模式不执行插件脚本。")
        }
        closeActionSession()
        let id = UUID()
        let targetPID = externalTargetPID
        actionID = id
        do {
            let session = try scriptExecutor.makeSession(
                manifest: command.manifest, pluginDirectory: command.pluginDirectory, commandID: commandID, query: query,
                hostCall: { [weak self] method, params in
                    guard let self else { throw PluginSessionError.closed }
                    return try await self.handleActionHostCall(method, params: params, id: id, command: command, targetPID: targetPID)
                }, onHostReply: { [weak self] method in
                    Task { @MainActor in
                        guard let self, self.actionID == id else { return }
                        if method == "runPlugin" {
                            self.activatePendingPluginRun()
                        } else if method == "outPlugin" || method == "hideMainWindow" || PluginHostAPI.inputMethods.contains(method) {
                            self.closeActionSession()
                            if method == "hideMainWindow" || PluginHostAPI.inputMethods.contains(method) { self.hideRequested?() }
                        }
                    }
                }
            )
            actionSession = session
            defer {
                session.close()
                if actionID == id { actionSession = nil; actionID = nil }
            }
            return .success(try await session.call("invoke", query: query).string ?? "")
        } catch {
            if actionID != id { return .success("") }
            actionSession = nil
            actionID = nil
            Self.logger.error("插件调用失败：\(error.localizedDescription)。")
            return .failure(error.localizedDescription)
        }
    }

    func closeActionSession() {
        actionID = nil
        actionSession?.close()
        actionSession = nil
    }

    private func handleActionHostCall(
        _ method: String, params: PluginValue, id: UUID, command: PluginCommandDescriptor, targetPID: Int32?
    ) async throws -> PluginValue {
        guard actionID == id, let hostAPI else { throw PluginSessionError.closed }
        return try await hostAPI.handle(method, params: params, context: .init(
            pluginID: command.pluginID, commandIDs: Set(command.manifest.commands.map(\.id)), targetPID: targetPID,
            isActive: { [weak self] in self?.actionID == id },
            setWindowHidden: { [weak self] hidden in self?.inputWindowVisibility?(hidden) }
        ))
    }

}

/// 启动器每次唤起/收起时的呈现生命周期。
extension LauncherModel {
    func requestSearchFocus() {
        focusRequestID &+= 1
    }

    func prepareForPresentation() {
        invocationRevision &+= 1
        closeActionSession()
        exitInteraction()
        // 收起即终止前台脚本，避免重新唤起时留下孤儿任务。
        exitShellRun()
        query = ""
        invocationState = .idle
    }
}

extension LauncherModel {
    /// 前台 Shell 运行/结果视图接管整个面板，不再显示搜索列表。
    var showsShellRun: Bool {
        if case .shellOutput = invocationState { return true }
        return false
    }

    func stopForegroundShell() {
        foregroundShellTask?.cancel()
    }

    /// 退出前台 Shell 运行视图，回到搜索。
    func exitShellRun() {
        stopForegroundShell()
        // 先断开关联，避免已终止任务的回调又把面板拉回运行视图。
        foregroundShellTask = nil
        shellRunCommand = nil
        invocationState = .idle
        requestSearchFocus()
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
                // 启动成功才把命令交给头部标签，启动失败仍展搜索界面与错误信息。
                shellRunCommand = command

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
                foregroundShellTask = nil
                shellRunCommand = nil
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
