import Foundation
import LeapCore
import Observation
import OSLog

@MainActor
@Observable
final class LauncherModel {
    enum InvocationState: Equatable {
        case idle
        case running(String)
        case result(String)
        case failed(String)
    }

    enum InvocationResponse: Sendable {
        case success(String)
        case failure(String)
    }

    private let catalog: InstalledPluginCatalog?
    let pluginPaths: AppPaths?
    private let recentStore: RecentCommandStore
    private let scriptExecutor: PluginScriptExecutor?
    private let fixtureCommands: [PluginCommandDescriptor]?

    var query = ""
    private(set) var commands: [PluginCommandDescriptor] = []
    private(set) var recentCommands: [PluginCommandDescriptor] = []
    private(set) var invocationState = InvocationState.idle
    private(set) var webCommand: PluginCommandDescriptor?
    private(set) var focusRequestID = 0

    init(paths: AppPaths) {
        catalog = InstalledPluginCatalog(paths: paths)
        pluginPaths = paths
        recentStore = RecentCommandStore()
        scriptExecutor = PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
        fixtureCommands = nil
    }

    init(fixtureCommands: [PluginCommandDescriptor], paths: AppPaths? = nil) {
        catalog = nil
        pluginPaths = paths
        recentStore = RecentCommandStore(defaults: .standard, key: "uiTestingRecentCommandKeys")
        scriptExecutor = nil
        self.fixtureCommands = fixtureCommands
    }

    var searchResults: [PluginCommandDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery) ||
                $0.pluginName.localizedCaseInsensitiveContains(normalizedQuery) ||
                $0.commandID.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func reloadPlugins() {
        commands = fixtureCommands ?? catalog?.load() ?? []
        rebuildRecentCommands()
    }

    func requestSearchFocus() {
        focusRequestID &+= 1
    }

    func activateFirstSearchResult() {
        guard let first = searchResults.first else {
            return
        }
        activate(first)
    }

    func activate(_ command: PluginCommandDescriptor) {
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
                Logger(subsystem: "com.padding.leap", category: "launcher-model")
                    .error("插件调用失败：\(error.localizedDescription, privacy: .public)。")
                return .failure(error.localizedDescription)
            }
        }.value
    }

    private func recordRecent(_ command: PluginCommandDescriptor) {
        let validKeys = Set(commands.map { RecentCommandKey(pluginID: $0.pluginID, commandID: $0.commandID) })
        recentStore.record(RecentCommandKey(pluginID: command.pluginID, commandID: command.commandID), validKeys: validKeys)
        rebuildRecentCommands()
    }

    private func rebuildRecentCommands() {
        let commandsByKey = Dictionary(uniqueKeysWithValues: commands.map {
            (RecentCommandKey(pluginID: $0.pluginID, commandID: $0.commandID), $0)
        })
        recentCommands = recentStore.load(validKeys: Set(commandsByKey.keys)).compactMap { commandsByKey[$0] }
    }
}
