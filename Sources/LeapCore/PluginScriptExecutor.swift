import Foundation
import YQLogger

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
    /// 共享 node daemon；为 nil 时全部会话走独立进程（测试与异常降级都靠这个）。
    public let daemon: PluginDaemon?

    public init(runtimeLocator: BundledRuntimeLocator, daemon: PluginDaemon? = nil) {
        self.runtimeLocator = runtimeLocator
        self.daemon = daemon
    }

    public func makeSession(
        manifest: PluginManifest, pluginDirectory: URL, commandID: String, query: String,
        hostCall: @escaping PluginProcessSession.HostCall = { _, _ in
            throw PluginSessionError.plugin("宿主接口不可用。")
        },
        onHostReply: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> PluginScriptSession {
        try makeSession(manifest: manifest, pluginDirectory: pluginDirectory, commandID: commandID, query: query,
                        hostCall: hostCall, onHostReply: onHostReply, useDaemon: true)
    }

    func makeSession(
        manifest: PluginManifest, pluginDirectory: URL, commandID: String, query: String,
        hostCall: @escaping PluginProcessSession.HostCall,
        onHostReply: @escaping @Sendable (String) -> Void,
        useDaemon: Bool
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
        // worker_threads 只能跑 JS；Python 仍走独立进程。
        let transport: PluginTransport
        var fallback: (@Sendable () -> PluginProcessSession)?
        if let daemon, useDaemon, manifest.runtime == .javascript {
            transport = .daemon(daemon, session: UUID().uuidString, entry: entry)
            // Worker 在 ready 之前起不来时降级成独立进程，第三方插件不会被新机制卡死。
            let pluginID = manifest.id
            fallback = {
                YQLogger(label: "com.padding.leap/plugin-session")
                    .notice("共享 daemon 启动插件失败，本次降级为独立进程：\(pluginID)。")
                return PluginProcessSession(executable: runtime, arguments: arguments, directory: pluginDirectory,
                                            hostCall: hostCall, onHostReply: onHostReply)
            }
        } else {
            transport = .process
        }
        return PluginScriptSession(process: PluginProcessSession(
            executable: runtime, arguments: arguments, directory: pluginDirectory, hostCall: hostCall,
            onHostReply: onHostReply, transport: transport
        ), commandID: commandID, initialInput: query, fallback: fallback)
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
/// 降级时会替换会话，用锁保护的盒子让 nonisolated 访问者总能拿到当前值。
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PluginProcessSession
    init(_ value: PluginProcessSession) { storage = value }
    var value: PluginProcessSession {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

public actor PluginScriptSession {
    private let processBox: ProcessBox
    private var process: PluginProcessSession { processBox.value }
    private let commandID: String
    private let initialInput: String
    private var enterTask: Task<Void, any Error>?
    /// 首次启动失败时的替代会话构造器；只允许降级一次，避免循环重启。
    private let fallback: (@Sendable () -> PluginProcessSession)?
    private var didFallback = false

    init(process: PluginProcessSession, commandID: String, initialInput: String,
         fallback: (@Sendable () -> PluginProcessSession)? = nil) {
        processBox = ProcessBox(process)
        self.commandID = commandID
        self.initialInput = initialInput
        self.fallback = fallback
    }

    public func start() async throws {
        if enterTask == nil {
            let process = process
            let commandID = commandID
            let query = initialInput
            enterTask = Task { _ = try await process.request("enter", commandID: commandID, query: query) }
        }
        do {
            try await enterTask?.value
        } catch {
            guard let fallback, !didFallback else { throw error }
            didFallback = true
            let replacement = fallback()
            processBox.value.close(commandID: commandID, query: initialInput)
            processBox.value = replacement
            enterTask = nil
            return try await start()
        }
    }

    public func call(
        _ method: String, commandID: String? = nil, query: String, itemID: String? = nil,
        cancellation: PluginInvocationCancellation? = nil, onList: PluginProcessSession.ListUpdate? = nil, onLoading: PluginProcessSession.LoadingUpdate? = nil
    ) async throws -> PluginValue {
        try await start()
        return try await process.request(method, commandID: commandID ?? self.commandID, query: query,
                                         itemID: itemID, cancellation: cancellation, onList: onList, onLoading: onLoading)
    }

    public nonisolated func close() {
        // 降级会替换 process，读一次当前值即可；关闭本身不要求 actor 隔离。
        let current = processBox.value
        current.close(commandID: commandID, query: initialInput)
    }

    /// 池用它挂会话生命周期回调；状态仍归会话自己的队列。
    public nonisolated var processSession: PluginProcessSession { processBox.value }

    /// 宿主推送事件给已注册 `leap.onHostEvent` 的插件；脚本不回帧。
    public nonisolated func notify(_ name: String, payload: PluginValue = .null) {
        processBox.value.notify(name, payload: payload)
    }
}
