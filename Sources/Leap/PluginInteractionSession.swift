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
        previousSearch: String, initialInput: String, executor: PluginScriptExecutor?
    ) {
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

    func handleHostCall(_ method: String, params: PluginValue) throws -> PluginValue {
        guard isActive else { throw PluginSessionError.closed }
        switch method {
        case "copyText":
            guard let text = params["text"]?.string else { throw PluginSessionError.invalidMessage }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                throw PluginSessionError.plugin("复制文本失败。")
            }
        case "outPlugin", "hideMainWindow": break
        default: throw PluginSessionError.plugin("未知宿主接口。")
        }
        return .bool(true)
    }

    enum SessionError: LocalizedError {
        case runtimeUnavailable
        var errorDescription: String? { "插件运行时不可用。" }
    }
}
