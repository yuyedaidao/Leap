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
        case let .application(application): application.displayName ?? application.name
        case let .plugin(command): command.title
        }
    }

    /// 应用不再显示副标题：Bundle ID 对用户没有意义，同名副本已由包名标题区分。
    var subtitle: String? {
        switch self {
        case .application: nil
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
        case let .application(application): "launcher.application.\(application.bundleIdentifier ?? application.id)"
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
    private let clipboardHistory: ClipboardHistoryStore?
    private let sessionPool: PluginSessionPool?
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
    /// 最近使用记录的清理必须等两侧目录都就绪，否则会把尚未加载的条目当成已卸载。
    private var didLoadCommands = false
    private var didLoadApplications = false

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
        let wiring = Self.makeClipboardWiring(paths: paths, hostAPI: hostAPI)
        clipboardHistory = wiring.store
        clipboardMonitor = wiring.monitor
        sessionPool = PluginSessionPool()
        recentStore = LauncherUsageStore()
        scriptExecutor = Self.makeScriptExecutor(paths: paths)
        shellExecutor = ShellScriptExecutor()
        fixtureCommands = nil
        fixtureApplications = nil
        applicationScanner = SystemApplicationScanner()
        applicationIndexCacheURL = paths.applicationIndexCacheURL
        applicationLauncher = Self.launchSystemApplication
        wireClipboardAppend(to: wiring.store)
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
        clipboardHistory = nil
        sessionPool = nil
        recentStore = LauncherUsageStore(defaults: .standard, key: "uiTestingLauncherUsageRecords")
        scriptExecutor = nil
        shellExecutor = nil
        self.fixtureCommands = fixtureCommands
        self.fixtureApplications = fixtureApplications
        applicationScanner = nil
        applicationIndexCacheURL = nil
        self.applicationLauncher = applicationLauncher
        applications = fixtureApplications
        // 夹具同时提供两侧目录，可直接参与记录清理。
        didLoadApplications = true
    }

    var searchResults: [LauncherItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }
        let usage = Dictionary(recentStore.load().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
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
        didLoadCommands = true
        commandMatchers = Dictionary(uniqueKeysWithValues: commands.map { command in
            (command.id, PluginCommandMatcher(command: configuration(for: command), pluginName: command.pluginName))
        })
        if let interaction, !commands.contains(where: { $0 == interaction.command }) { exitInteraction() }
        if let fixtureApplications { applications = fixtureApplications }
        rebuildRecentItems()
        pruneUsageRecords()
        prewarmClipboardSession()
    }

    func clearRecentItems() {
        recentStore.clear()
        rebuildRecentItems()
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
            self.didLoadApplications = true
            self.rebuildRecentItems()
            self.pruneUsageRecords()
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
                hostAPI: hostAPI, targetPID: externalTargetPID, inputWindowVisibility: inputWindowVisibility,
                pool: sessionPool
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
        // 保留脚本进程一小段时间，下次打开省掉 Node 冷启。
        interaction.suspend()
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
        recentStore.record(.plugin(RecentCommandKey(pluginID: command.pluginID, commandID: command.commandID)))
        rebuildRecentItems()
    }


    private func activate(_ application: SystemApplicationDescriptor) {
        // 运行/失败反馈沿用标题，否则两份 Xcode 分不清是哪一份。
        let displayName = application.displayName ?? application.name
        invocationState = .running(displayName)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await applicationLauncher(application.url)
                guard !Task.isCancelled else { return }
                recentStore.record(.application(path: application.historyKey))
                rebuildRecentItems()
                applicationDidLaunch?()
            } catch {
                Self.logger.error("启动应用失败：\(displayName)，\(error.localizedDescription)。")
                invocationState = .failed("无法启动 \(displayName)：\(error.localizedDescription)")
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
            didLoadApplications = true
            rebuildRecentItems()
            pruneUsageRecords()
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

/// 最近使用列表只做展示过滤，清理必须等两侧目录都就绪后再执行。
extension LauncherModel {
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

    /// 所有 JS 插件共享一个常驻 node daemon：115MB 运行时的冷加载只在 App 生命周期内付一次。
    private static func makeScriptExecutor(paths: AppPaths) -> PluginScriptExecutor {
        let locator = BundledRuntimeLocator(paths: paths)
        let daemon = (try? locator.executable(for: .javascript)).map { executable in
            PluginDaemon(executable: executable,
                         script: paths.resourceDirectory.appendingPathComponent("PluginSDK/daemon.cjs"))
        }
        return PluginScriptExecutor(runtimeLocator: locator, daemon: daemon)
    }

    func rebuildRecentItems() {
        var items: [LauncherUsageKey: LauncherItem] = [:]
        for item in applications.map(LauncherItem.application) + commands.map(LauncherItem.plugin) {
            items[item.usageKey] = item
        }
        // 记录里可能残留尚未清理到位的条目，展示时直接跳过，但不在读取阶段删除。
        var seen = Set<LauncherUsageKey>()
        recentItems = recentStore.load().compactMap { record in
            guard seen.insert(record.key).inserted else { return nil }
            return items[record.key]
        }
    }

    func pruneUsageRecords() {
        guard didLoadCommands, didLoadApplications else { return }
        recentStore.prune(keeping: validUsageKeys)
        rebuildRecentItems()
    }
}
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

/// 剪切板历史的宿主侧组装：主模型只持有实例，具体接线放在扩展里，避免类体继续膨胀。
@MainActor
extension LauncherModel {
    private struct ClipboardWiring {
        let store: ClipboardHistoryStore
        let monitor: ClipboardHistoryMonitor
    }

    /// 建立分组日志存储并启动轮询；旧文档库在首次启动时迁移过来。
    private static func makeClipboardWiring(paths: AppPaths, hostAPI: PluginHostAPI) -> ClipboardWiring {
        let store = ClipboardHistoryStore(directory: paths.clipboardDataDirectory)
        store.migrateLegacyHistory(legacyDirectory: paths.clipboardHistoryDirectory,
                                   documentStores: hostAPI.documentStores)
        hostAPI.clipboardHistory = store
        let monitor = ClipboardHistoryMonitor(store: store)
        hostAPI.onClipboardWrite = { [weak monitor] in monitor?.suppressNextCapture() }
        monitor.start()
        return ClipboardWiring(store: store, monitor: monitor)
    }

    /// 新记录直接推给正在交互的剪切板插件，列表不必重新请求宿主。
    private func wireClipboardAppend(to store: ClipboardHistoryStore) {
        store.onAppend = { [weak self] record in
            guard let self, let interaction,
                  interaction.command.pluginID == AppPaths.clipboardPluginID else { return }
            interaction.notify("clipboard.append", payload: record.pluginValue)
            interaction.reloadList()
        }
    }

    /// 启动后在空闲时预热剪切板会话，把首次打开的冷启代价移出交互路径。
    private func prewarmClipboardSession() {
        guard let sessionPool, let scriptExecutor, interaction == nil,
              let command = commands.first(where: { $0.pluginID == AppPaths.clipboardPluginID }) else { return }
        let key = PluginSessionPool.Key(pluginID: command.pluginID, commandID: command.commandID)
        let daemon = scriptExecutor.daemon
        Task { [weak self] in
            // daemon 进程本身也要在空闲时拉起，否则首次打开仍要等运行时加载。
            try? daemon?.start()
            try? await Task.sleep(for: .seconds(1))
            // 用户已经先一步打开时不再重复创建会话。
            guard let self, self.interaction == nil else { return }
            sessionPool.prewarm(key, executor: scriptExecutor, manifest: command.manifest,
                                pluginDirectory: command.pluginDirectory)
        }
    }

    var canRebuildApplicationIndex: Bool {
        applicationScanner != nil && applicationIndexCacheURL != nil
    }
}
