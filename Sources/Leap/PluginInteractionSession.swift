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
    let list: PluginListSession?
    var inputText: String
    private(set) var committedInput: String
    private(set) var submitID = 0
    private(set) var isActive = true
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
        if configuration.presentation == .list {
            list = PluginListSession { method, query, itemID, cancellation in
                guard let executor else { throw SessionError.runtimeUnavailable }
                return try await Task.detached(priority: .userInitiated) {
                    try executor.invoke(
                        manifest: command.manifest, pluginDirectory: command.pluginDirectory,
                        commandID: command.commandID, query: query, method: method,
                        itemID: itemID, cancellation: cancellation
                    )
                }.value
            }
            list?.updateInput(initialInput)
        } else {
            list = nil
        }
    }

    func commitInput(_ text: String) {
        guard isActive, committedInput != text else { return }
        committedInput = text
        list?.updateInput(text)
    }

    func submit() {
        guard isActive else { return }
        if let list { list.select() } else { submitID &+= 1 }
    }

    func close() {
        guard isActive else { return }
        isActive = false
        list?.close()
        exitWebPage?()
        exitWebPage = nil
    }

    enum SessionError: LocalizedError {
        case runtimeUnavailable
        var errorDescription: String? { "插件运行时不可用。" }
    }
}
