import Darwin
import Foundation
import YQLogger

/// 常驻的 JS 插件宿主进程：把「每个会话一个 node 进程」换成「一个 node daemon 内每个会话一个 Worker」。
/// 大二进制首次加载的 2.5s 只付一次，之后新会话是毫秒级。
public final class PluginDaemon: @unchecked Sendable {
    public enum DaemonError: LocalizedError {
        case missingScript(URL)
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case let .missingScript(url): "缺少插件运行时脚本：\(url.lastPathComponent)。"
            case let .unavailable(reason): "插件运行时不可用：\(reason)"
            }
        }
    }

    /// 一个 Worker 会话的输入事件；由 PluginProcessSession 实现。
    public protocol SessionHandler: AnyObject, Sendable {
        func daemonReceive(_ message: PluginDaemon.Frame)
        func daemonFailed(_ error: any Error)
    }

    public struct Frame: Sendable {
        public let type: String
        public let id: String
        public let method: String?
        public let parentID: String?
        public let params: PluginValue?
        public let value: PluginValue?
        public let error: String?
    }

    private final class Handler: @unchecked Sendable {
        weak var value: SessionHandler?
        init(_ value: SessionHandler) { self.value = value }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: PluginDaemon] = [:]

    /// 退出时先停所有 Worker，再停 daemon 进程，避免留下孤儿 node。
    public static func terminateAll() {
        let daemons = registryLock.withLock { Array(registry.values) }
        for daemon in daemons { daemon.shutdown() }
    }

    private let logger = YQLogger(label: "com.padding.leap/plugin-daemon")
    private let lock = NSLock()
    /// 管道写入单独串行：锁只保护状态，不覆盖可能阻塞的大帧写，避免读路径被写阻塞拖死。
    private let writer = DispatchQueue(label: "com.padding.leap/plugin-daemon-writer", qos: .userInitiated)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var handlers: [String: Handler] = [:]
    private var buffer = Data()
    private var logBytes = Data()
    private var stopping = false

    private let executable: URL
    private let script: URL
    private let directory: URL?

    public init(executable: URL, script: URL, directory: URL? = nil) {
        self.executable = executable
        self.script = script
        self.directory = directory
        _ = Self.registryLock.withLock { Self.registry[ObjectIdentifier(self)] = self }
    }

    /// 登记一个会话；真正的 Worker 在首帧发送时才创建，避免空会话也占内存。
    public func attach(_ session: String, handler: SessionHandler) {
        lock.withLock { handlers[session] = Handler(handler) }
    }

    /// 启动 daemon 进程本身；重复调用是幂等的。
    public func start() throws {
        try lock.withLock { try startLocked() }
    }

    public func spawn(_ session: String, entry: URL) throws {
        try lock.withLock {
            try startLocked()
            let root = directory ?? entry.deletingLastPathComponent()
            try sendLocked(["op": .string("spawn"), "session": .string(session),
                            "entry": .string(entry.path), "directory": .string(root.path)])
        }
    }

    public func write(_ frame: [String: PluginValue], session: String) {
        lock.withLock {
            guard process != nil else { return }
            // 信封（op/session）与协议帧分开：插件只应该看到原始帧
            let envelope: [String: PluginValue] = [
                "op": .string("write"), "session": .string(session), "message": .object(frame)
            ]
            try? sendLocked(envelope)
        }
    }

    public func close(_ session: String) {
        lock.withLock {
            guard process != nil else { return }
            try? sendLocked(["op": .string("close"), "session": .string(session)])
        }
    }

    public func detach(_ session: String) {
        lock.withLock { handlers.removeValue(forKey: session) }
    }

    /// daemon 的 pid；同一 daemon 内所有会话共享，满足「同一会话 pid 不变」的既有断言。
    public var processIdentifier: Int32 {
        lock.withLock { process?.processIdentifier ?? 0 }
    }

    public func shutdown() {
        let (process, input, output, errors) = lock.withLock {
            stopping = true
            let value = (self.process, self.input, self.output, self.errors)
            self.process = nil
            self.input = nil
            self.output = nil
            self.errors = nil
            self.handlers.removeAll()
            return value
        }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        try? errors?.fileHandleForReading.close()
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
            if let identifier = process?.processIdentifier {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { kill(identifier, SIGKILL) }
            }
        }
        Self.registryLock.withLock { Self.registry.removeValue(forKey: ObjectIdentifier(self)) }
    }

    private func startLocked() throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DaemonError.missingScript(executable)
        }
        guard FileManager.default.fileExists(atPath: script.path) else { throw DaemonError.missingScript(script) }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = [script.path]
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            self?.processExited(status: finished.terminationStatus)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.ingest(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.withLock {
                self.logBytes.append(data)
                if self.logBytes.count > 65536 { self.logBytes = self.logBytes.suffix(65536) }
            }
        }
        try process.run()
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        logger.debug("已启动插件 daemon：\(process.processIdentifier)。")
    }

    private func sendLocked(_ fields: [String: PluginValue]) throws {
        guard let input else { throw DaemonError.unavailable("daemon 未运行。") }
        let frame = try JSONEncoder().encode(PluginValue.object(fields)) + Data([10])
        guard frame.count <= 24 * 1024 * 1024 else { throw PluginSessionError.messageTooLarge }
        // 调用方已持锁，入队顺序即帧顺序；真正的阻塞写留在锁外。
        let handle = input.fileHandleForWriting
        writer.async { try? handle.write(contentsOf: frame) }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            guard !stopping else { return }
            buffer.append(data)
            // daemon 与插件共用 24MB 上限，防止单个异常帧无限增长。
            while let index = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<index]
                buffer = buffer[(index + 1)...]
                guard !line.isEmpty else { continue }
                guard let frame = try? JSONDecoder().decode(PluginValue.self, from: Data(line)) else { continue }
                handle(frame)
            }
            if buffer.count > 24 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: true)
                failAll(DaemonError.unavailable("daemon 输出帧过大。"))
            }
        }
    }

    private func handle(_ value: PluginValue) {
        guard case let .object(fields) = value, case let .string(session)? = fields["session"] else { return }
        if case let .string(type)? = fields["type"], type == "__daemon" {
            // fatal 是 Worker 抛异常，exited 是 Worker 自行退出（插件调 process.exit，或 bootstrap 把
            // 插件加载失败、worker 不支持的 API 转成 exit(1)）。两种都必须立刻收尾，否则会话变僵尸、
            // 请求要等满 3s 超时才失败，降级也就晚 3s。
            switch string(of: fields["op"]) {
            case "fatal":
                let detail = string(of: fields["detail"]) ?? ""
                logger.error("插件 Worker 失败（\(session)）：\(detail)。")
                failSession(session, DaemonError.unavailable(detail))
            case "exited":
                let code = string(of: fields["detail"]) ?? "?"
                logger.notice("插件 Worker 已退出（\(session)，exit=\(code)）。")
                failSession(session, DaemonError.unavailable("插件进程退出（exit=\(code)）。"))
            default:
                break
            }
            return
        }
        var payload: [String: PluginValue] = [:]
        for (key, field) in fields where key != "session" { payload[key] = field }
        guard case let .string(type)? = payload["type"], case let .string(rawID)? = payload["id"] else { return }
        // daemon 出口给 ready 与 host-N 加过会话前缀，回程在这里还原，会话内部仍旧用原 id 语义。
        var id = rawID
        if id.hasPrefix(session + "/") {
            let rest = String(id.dropFirst(session.count + 1))
            if rest == "ready" || rest.hasPrefix("host-") { id = rest }
        }
        let frame = Frame(type: type, id: id, method: string(of: payload["method"]),
                          parentID: string(of: payload["parentID"]), params: payload["params"],
                          value: payload["value"], error: string(of: payload["error"]))
        handlers[session]?.value?.daemonReceive(frame)
    }

    private func failSession(_ session: String, _ error: any Error) {
        // 主动关闭的会话已在 finishClose 里 detach，这里取不到就说明无需通知。
        handlers.removeValue(forKey: session)?.value?.daemonFailed(error)
    }

    private func string(of value: PluginValue?) -> String? {
        guard case let .string(text)? = value else { return nil }
        return text
    }

    private func processExited(status: Int32) {
        let (sessions, log) = lock.withLock { () -> ([SessionHandler], String) in
            let sessions = handlers.values.compactMap(\.value)
            handlers.removeAll()
            let log = String(decoding: logBytes, as: UTF8.self)
            process = nil
            input = nil
            output = nil
            errors = nil
            return (sessions, log)
        }
        logger.notice("插件 daemon 已退出（\(status)）：\(log)")
        let error = DaemonError.unavailable("daemon 退出（\(status)）：" + log)
        for session in sessions { session.daemonFailed(error) }
    }

    private func failAll(_ error: any Error) {
        let sessions = handlers.values.compactMap(\.value)
        handlers.removeAll()
        for session in sessions { session.daemonFailed(error) }
    }
}
