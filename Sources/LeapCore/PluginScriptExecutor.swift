import Foundation

public struct BundledRuntimeLocator: Sendable {
    public enum RuntimeError: LocalizedError, Equatable {
        case missingRuntime(PluginManifest.Runtime)

        public var errorDescription: String? {
            switch self {
            case .missingRuntime(.python): "Leap 随包 Python 运行时不可用。"
            case .missingRuntime(.javascript): "Leap 随包 Node.js 运行时不可用。"
            case .missingRuntime(.shell): "系统 zsh 运行时不可用。"
            }
        }
    }

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func executable(for runtime: PluginManifest.Runtime, fileManager: FileManager = .default) throws -> URL {
        let executable: URL
        switch runtime {
        case .python:
            executable = paths.runtimesDirectory
                .appendingPathComponent("python-3.14.7/Versions/3.14/bin/python3.14")
        case .javascript:
            executable = paths.runtimesDirectory
                .appendingPathComponent("node-24.21.0/bin/node")
        case .shell:
            executable = URL(fileURLWithPath: "/bin/zsh")
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw RuntimeError.missingRuntime(runtime)
        }
        return executable
    }
}

public struct PluginScriptExecutor: Sendable {
    let runtimeLocator: BundledRuntimeLocator

    public init(runtimeLocator: BundledRuntimeLocator) { self.runtimeLocator = runtimeLocator }

    public func makeSession(
        manifest: PluginManifest, pluginDirectory: URL, commandID: String, query: String,
        hostCall: @escaping PluginProcessSession.HostCall = { _, _ in
            throw PluginSessionError.plugin("宿主接口不可用。")
        },
        onHostReply: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> PluginScriptSession {
        let entry = pluginDirectory.appendingPathComponent(manifest.entry).standardizedFileURL
        guard entry.path.hasPrefix(pluginDirectory.standardizedFileURL.path + "/") else {
            throw PluginManifestValidator.ValidationError.invalidEntry
        }
        let runtime = try runtimeLocator.executable(for: manifest.runtime)
        let sdk = runtimeLocator.paths.resourceDirectory.appendingPathComponent("PluginSDK")
        let bootstrapName = manifest.runtime == .python ? "bootstrap.py" : "bootstrap.cjs"
        let bootstrap = sdk.appendingPathComponent(bootstrapName)
        guard FileManager.default.fileExists(atPath: bootstrap.path) else {
            throw PluginSessionError.plugin("Leap SDK 资源不可用。")
        }
        // Python 缓存不能写回已签名的应用资源，否则会破坏发行包的资源封印。
        let arguments = (manifest.runtime == .python ? ["-B"] : []) + [bootstrap.path, entry.path]
        return PluginScriptSession(process: PluginProcessSession(
            executable: runtime, arguments: arguments, directory: pluginDirectory, hostCall: hostCall, onHostReply: onHostReply
        ), commandID: commandID, initialInput: query)
    }

    public func invoke(
        manifest: PluginManifest, pluginDirectory: URL, commandID: String, query: String,
        method: String = "invoke", itemID: String? = nil,
        cancellation: PluginInvocationCancellation? = nil
    ) async throws -> PluginValue {
        let session = try makeSession(manifest: manifest, pluginDirectory: pluginDirectory,
                                      commandID: commandID, query: query)
        defer { session.close() }
        return try await session.call(method, query: query, itemID: itemID, cancellation: cancellation)
    }
}

/// 初始化只执行一次；网页的动作调用和原生列表共享同一会话进程。
public actor PluginScriptSession {
    private let process: PluginProcessSession
    private let commandID: String
    private let initialInput: String
    private var enterTask: Task<Void, any Error>?

    init(process: PluginProcessSession, commandID: String, initialInput: String) {
        self.process = process
        self.commandID = commandID
        self.initialInput = initialInput
    }

    public func start() async throws {
        if enterTask == nil {
            let process = process
            let commandID = commandID
            let query = initialInput
            enterTask = Task { _ = try await process.request("enter", commandID: commandID, query: query) }
        }
        try await enterTask?.value
    }

    public func call(
        _ method: String, commandID: String? = nil, query: String, itemID: String? = nil,
        cancellation: PluginInvocationCancellation? = nil, onList: PluginProcessSession.ListUpdate? = nil, onLoading: PluginProcessSession.LoadingUpdate? = nil
    ) async throws -> PluginValue {
        try await start()
        return try await process.request(method, commandID: commandID ?? self.commandID, query: query,
                                         itemID: itemID, cancellation: cancellation, onList: onList, onLoading: onLoading)
    }

    public nonisolated func close() { process.close(commandID: commandID, query: initialInput) }
}
