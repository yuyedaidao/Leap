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
    private var webHostTasks: [String: Task<PluginValue, any Error>] = [:]

    private var startupError: String?
    var errorMessage: String? {
        startupError ?? (list == nil && inputCoordinator?.isError == true ? inputCoordinator?.message : nil)
    }
    var hostAction: ((String) -> Void)?
    var inputText: String
    private(set) var committedInput: String
    private(set) var submitID = 0
    private(set) var isActive = true
    private var inputCoordinator: PluginListSession?
    var exitWebPage: (() -> Void)?

    init(
        command: PluginCommandDescriptor, configuration: PluginManifest.Command,
        previousSearch: String, initialInput: String, executor: PluginScriptExecutor?,
        hostAPI: PluginHostAPI? = nil, targetPID: Int32? = nil, inputWindowVisibility: ((Bool) -> Void)? = nil
    ) {
        self.hostAPI = hostAPI
        self.targetPID = targetPID
        self.inputWindowVisibility = inputWindowVisibility
        self.command = command
        self.configuration = configuration
        self.previousSearch = previousSearch
        inputText = initialInput
        committedInput = initialInput
        do {
            guard let executor else { throw SessionError.runtimeUnavailable }
            let script = try executor.makeSession(
                manifest: command.manifest, pluginDirectory: command.pluginDirectory,
                commandID: command.commandID, query: initialInput,
                hostCall: { [weak self] method, params in
                    guard let self else { throw PluginSessionError.closed }
                    return try await self.handleHostCall(method, params: params)
                }, onHostReply: { [weak self] method in
                    Task { @MainActor in
                        guard let self, self.isActive else { return }
                        self.hostAction?(method)
                    }
                }
            )
            self.script = script
            let coordinator = PluginListSession { method, query, itemID, cancellation, update in
                try await script.call(method, query: query, itemID: itemID,
                                      cancellation: cancellation, onList: update)
            }
            inputCoordinator = coordinator
            if configuration.presentation == .list { list = coordinator }
            coordinator.updateInput(initialInput)
        } catch { startupError = error.localizedDescription }

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
        script?.close()
        exitWebPage?()
        exitWebPage = nil
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
