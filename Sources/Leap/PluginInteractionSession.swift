import AppKit
import Foundation
import LeapCore
import Observation

/// 当前插件的输入与生命周期独立于全局搜索，也不让 View 承担脚本副作用。
@MainActor
@Observable
final class PluginInteractionSession: Identifiable {
    let id = UUID()
    let command: PluginCommandDescriptor
    let configuration: PluginManifest.Command
    let previousSearch: String
    private(set) var list: PluginListSession?
    private var script: PluginScriptSession?
    private let hostAPI: PluginHostAPI?
    private let targetPID: Int32?
    private let inputWindowVisibility: ((Bool) -> Void)?
    private let pool: PluginSessionPool?
    private let poolKey: PluginSessionPool.Key?
    private var pooled: PluginSessionPool.Session?
    private var webHostTasks: [String: Task<PluginValue, any Error>] = [:]

    private var startupError: String?
    var errorMessage: String? {
        startupError ?? (list == nil && inputCoordinator?.isError == true ? inputCoordinator?.message : nil)
    }
    var hostAction: ((String) -> Void)?
    /// 跨插件启动：宿主回复送达后再切换，避免调用方等不到结果。
    var onPluginRun: (() -> Void)?
    var inputText: String
    private(set) var committedInput: String
    private(set) var submitID = 0
    private(set) var isActive = true
    private var inputCoordinator: PluginListSession?
    var exitWebPage: (() -> Void)?

    init(
        command: PluginCommandDescriptor, configuration: PluginManifest.Command,
        previousSearch: String, initialInput: String, executor: PluginScriptExecutor?,
        hostAPI: PluginHostAPI? = nil, targetPID: Int32? = nil, inputWindowVisibility: ((Bool) -> Void)? = nil,
        pool: PluginSessionPool? = nil
    ) {
        self.hostAPI = hostAPI
        self.targetPID = targetPID
        self.inputWindowVisibility = inputWindowVisibility
        self.command = command
        self.configuration = configuration
        self.previousSearch = previousSearch
        self.pool = pool
        poolKey = pool.map { _ in PluginSessionPool.Key(pluginID: command.pluginID, commandID: command.commandID) }
        inputText = initialInput
        committedInput = initialInput
        do {
            let source = try resolveScript(executor: executor, initialInput: initialInput)
            script = source.script
            let scriptSession = source.script
            pooled = source.pooled
            pooled?.router.session = self
            let call: PluginListSession.Call = { [weak self] method, query, itemID, cancellation, update in
                let owner = self
                let loading: PluginProcessSession.LoadingUpdate?
                if configuration.presentation == .list {
                    loading = { [weak owner] visible in
                        Task { @MainActor [weak owner] in
                            owner?.list?.setLoading(visible, cancellation: cancellation)
                        }
                    }
                } else { loading = nil }
                return try await scriptSession.call(method, query: query, itemID: itemID,
                                                    cancellation: cancellation, onList: update, onLoading: loading)
            }
            let snapshot = source.snapshot ?? PluginListSnapshot(items: [])
            let coordinator = PluginListSession(initialSnapshot: snapshot, call: call)
            inputCoordinator = coordinator
            if configuration.presentation == .list { list = coordinator }
            coordinator.updateInput(initialInput)
        } catch { startupError = error.localizedDescription }

    }

    private struct Source {
        let script: PluginScriptSession
        let pooled: PluginSessionPool.Session?
        let snapshot: PluginListSnapshot?
    }

    /// 优先复用池内会话，其次新建；池内会话还带回它上次的列表快照。
    private func resolveScript(executor: PluginScriptExecutor?, initialInput: String) throws -> Source {
        if let pool, let poolKey, let borrowed = pool.borrow(poolKey) {
            return Source(script: borrowed.session.script, pooled: borrowed.session, snapshot: borrowed.snapshot)
        }
        guard let executor else { throw SessionError.runtimeUnavailable }
        if let pool, let poolKey {
            let session = try pool.makeSession(executor: executor, manifest: command.manifest,
                                               pluginDirectory: command.pluginDirectory,
                                               commandID: command.commandID, query: initialInput)
            return Source(script: session.script, pooled: session, snapshot: nil)
        }
        let script = try executor.makeSession(
            manifest: command.manifest, pluginDirectory: command.pluginDirectory,
            commandID: command.commandID, query: initialInput,
            hostCall: { [weak self] method, params in
                guard let self else { throw PluginSessionError.closed }
                return try await self.handleHostCall(method, params: params)
            },
            onHostReply: { [weak self] method in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.didReplyHostCall(method)
                }
            }
        )
        return Source(script: script, pooled: nil, snapshot: nil)
    }

    func commitInput(_ text: String) {
        guard isActive, committedInput != text else { return }
        committedInput = text
        inputCoordinator?.updateInput(text)
    }

    func submit() {
        guard isActive else { return }
        if let list { list.select() } else { submitID &+= 1 }
    }

    func close() {
        guard isActive else { return }
        isActive = false
        for task in webHostTasks.values { task.cancel() }
        webHostTasks.removeAll()
        list?.close()
        inputCoordinator?.close()
        pooled?.router.session = nil
        pooled = nil
        script?.close()
        script = nil
        exitWebPage?()
        exitWebPage = nil
    }

    /// 退出交互但保留脚本进程，交给池复用；无池时等同于关闭。
    func suspend() {
        guard isActive, let pool, let poolKey, let pooled else { close(); return }
        isActive = false
        for task in webHostTasks.values { task.cancel() }
        webHostTasks.removeAll()
        let snapshot = list?.snapshot
        list?.close()
        inputCoordinator?.close()
        self.pooled = nil
        script = nil
        exitWebPage?()
        exitWebPage = nil
        pool.recycle(pooled, snapshot: snapshot, for: poolKey)
    }

    /// 宿主推送只传递数据：插件更新内存副本后由 `reloadList()` 重跑当前查询。
    func notify(_ name: String, payload: PluginValue = .null) {
        guard isActive else { return }
        script?.notify(name, payload: payload)
    }

    func reloadList() {
        guard isActive, let inputCoordinator else { return }
        inputCoordinator.updateInput(inputText)
    }

    func didReplyHostCall(_ method: String) {
        guard isActive else { return }
        if method == "runPlugin" { onPluginRun?() } else { hostAction?(method) }
    }

    func invoke(commandID: String, query: String) async -> LauncherModel.InvocationResponse {
        guard isActive, command.manifest.commands.contains(where: { $0.id == commandID }), let script else {
            return .failure("插件会话或命令无效。")
        }
        do {
            return .success(try await script.call("invoke", commandID: commandID, query: query).string ?? "")
        } catch { return .failure(error.localizedDescription) }
    }

    func handleHostCall(_ method: String, params: PluginValue) async throws -> PluginValue {
        guard isActive, let hostAPI else { throw PluginSessionError.closed }
        return try await hostAPI.handle(method, params: params, context: .init(
            pluginID: command.pluginID, commandIDs: Set(command.manifest.commands.map(\.id)), targetPID: targetPID,
            isActive: { [weak self] in self?.isActive == true },
            setWindowHidden: { [weak self] hidden in self?.inputWindowVisibility?(hidden) }
        ))
    }

    func startWebHostCall(_ method: String, params: PluginValue, callID: String) throws -> Task<PluginValue, any Error> {
        guard isActive, webHostTasks.count < 16, webHostTasks[callID] == nil else { throw PluginSessionError.closed }
        // 同步登记，取消消息即使早于异步执行到达也能找到任务。
        let task = Task {
            let value = try await self.handleHostCall(method, params: params)
            if Task.isCancelled { throw PluginSessionError.cancelled }
            return value
        }
        webHostTasks[callID] = task
        return task
    }

    func cancelWebHostCall(_ callID: String) { webHostTasks[callID]?.cancel() }

    func finishWebHostCall(_ callID: String) { webHostTasks[callID] = nil }

    enum SessionError: LocalizedError {
        case runtimeUnavailable
        var errorDescription: String? { "插件运行时不可用。" }
    }
}
