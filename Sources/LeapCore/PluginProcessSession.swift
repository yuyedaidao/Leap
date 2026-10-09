import Darwin
import Foundation
import YQLogger

public enum PluginSessionError: LocalizedError, Equatable {
    case closed, timedOut, invalidMessage, messageTooLarge, cancelled
    case plugin(String)
    public var errorDescription: String? {
        switch self {
        case .closed: "插件会话已关闭，请退出后重新进入。"
        case .timedOut: "插件响应超时，请退出后重新进入。"
        case .invalidMessage: "插件通信消息无效。"
        case .messageTooLarge: "插件消息超过 1MB。"
        case .cancelled: "插件输入已取消。"
        case let .plugin(message): "插件执行失败：\(message)"
        }
    }
}

private struct PluginMessage: Codable, Sendable {
    var protocolVersion = 1
    let type: String
    let id: String
    var method: String?
    var params: PluginValue?
    var value: PluginValue?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type, id, method, params, value, error
    }
}

extension PluginMessage {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(PluginValue.self, forKey: .params)
        // null 是合法的无反馈结果，必须区分“值为 null”和“缺少 value 字段”。
        value = container.contains(.value) ? try container.decode(PluginValue.self, forKey: .value) : nil
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// 所有可变状态限定在队列内；文件句柄回调只投递数据，不在主线程阻塞读写。
public final class PluginProcessSession: @unchecked Sendable {
    public typealias HostCall = @Sendable (String, PluginValue) async throws -> PluginValue
    public typealias ListUpdate = @Sendable ([PluginListItem]) -> Void
    private struct Pending {
        let message: PluginMessage
        let continuation: CheckedContinuation<PluginValue, any Error>
        let deadline: DispatchWorkItem
        let cancellation: PluginInvocationCancellation?
        let observation: UUID?
        let listUpdate: ListUpdate?
    }
    private final class WeakSession: @unchecked Sendable {
        weak var value: PluginProcessSession?
        init(_ value: PluginProcessSession) { self.value = value }
    }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [WeakSession] = []

    /// 应用正在退出时不能依赖延迟计时器执行，立即清理仅由本宿主创建的进程。
    public static func terminateAll() {
        let sessions = registryLock.withLock { registry.compactMap(\.value) }
        for session in sessions {
            session.queue.sync {
                if session.process.isRunning { kill(session.process.processIdentifier, SIGKILL) }
                session.finishClose()
            }
        }
    }

    private let queue = DispatchQueue(label: "com.padding.leap/plugin-session", qos: .userInitiated)
    private let writer = DispatchQueue(label: "com.padding.leap/plugin-writer", qos: .userInitiated)
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let hostCall: HostCall
    private let onHostReply: @Sendable (String) -> Void
    private let logger = YQLogger(label: "com.padding.leap/plugin-session")
    private var pending: [String: Pending] = [:]
    private var bytes = Data()
    private var logBytes = Data()
    private var started = false
    private var ready = false
    private var closed = false
    private var shuttingDown = false
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private let sessionID = UUID().uuidString

    public init(executable: URL, arguments: [String], directory: URL? = nil,
                hostCall: @escaping HostCall = { _, _ in throw PluginSessionError.plugin("宿主接口不可用。") },
                onHostReply: @escaping @Sendable (String) -> Void = { _ in }) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.hostCall = hostCall
        self.onHostReply = onHostReply
        Self.registryLock.withLock {
            Self.registry.removeAll { $0.value == nil }
            Self.registry.append(WeakSession(self))
        }
    }

    public func request(
        _ method: String, commandID: String, query: String, itemID: String? = nil,
        cancellation: PluginInvocationCancellation? = nil, timeout: TimeInterval = 3,
        onList: ListUpdate? = nil
    ) async throws -> PluginValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed, !shuttingDown, pending.count < 16 else { continuation.resume(throwing: PluginSessionError.closed); return }
                guard cancellation?.isCancelled != true else {
                    continuation.resume(throwing: PluginSessionError.cancelled); return
                }
                let id = sessionID + "/" + UUID().uuidString
                var params: [String: PluginValue] = ["commandID": .string(commandID), "query": .string(query)]
                if let itemID { params["itemID"] = .string(itemID) }
                let message = PluginMessage(type: "event", id: id, method: method, params: .object(params))
                do {
                    _ = try encoded(message)
                    let deadline = DispatchWorkItem { [weak self] in self?.fail(PluginSessionError.timedOut) }
                    let observation = cancellation?.observe { [weak self] in
                        guard let self else { return }
                        self.queue.async {
                            guard self.pending[id] != nil, self.ready else { return }
                            self.send(PluginMessage(type: "cancel", id: id))
                        }
                    }
                    pending[id] = Pending(message: message, continuation: continuation, deadline: deadline,
                                          cancellation: cancellation, observation: observation, listUpdate: onList)
                    queue.asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
                    try startIfNeeded()
                    if ready { send(message) }
                } catch {
                    if pending[id] != nil { fail(error) } else { continuation.resume(throwing: error) }
                }
            }
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public func close(commandID: String = "", query: String = "") {
        queue.async { [self] in
            guard !closed, !shuttingDown else { return }
            shuttingDown = true
            for id in pending.keys { send(PluginMessage(type: "cancel", id: id)) }
            resumePending(PluginSessionError.closed)
            if ready {
                send(PluginMessage(type: "event", id: sessionID + "/exit", method: "exit",
                                   params: .object(["commandID": .string(commandID), "query": .string(query)])))
                queue.asyncAfter(deadline: .now() + 0.25) { [self] in finishClose() }
            } else { finishClose() }
        }
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        started = true
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                self.logBytes.append(data)
                if self.logBytes.count > 65536 { self.logBytes = self.logBytes.suffix(65536) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            self.queue.async {
                if !self.closed {
                    self.fail(PluginSessionError.plugin("进程退出（\(status)）：" + String(decoding: self.logBytes, as: UTF8.self)))
                }
            }
        }
        try process.run()
        logger.debug("已启动插件会话进程：\(process.processIdentifier)。")
    }

    private func encoded(_ message: PluginMessage) throws -> Data {
        let data = try JSONEncoder().encode(message) + Data([10])
        guard data.count <= 1024 * 1024 else { throw PluginSessionError.messageTooLarge }
        return data
    }

    private func send(_ message: PluginMessage, completion: (@Sendable () -> Void)? = nil) {
        guard !closed else { return }
        do {
            let data = try encoded(message)
            let handle = input.fileHandleForWriting
            writer.async { [weak self] in
                do { try handle.write(contentsOf: data); completion?() }
                catch {
                    guard let self else { return }
                    self.queue.async { if !self.closed { self.fail(error) } }
                }
            }
        } catch { fail(error) }
    }

    private func receive(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        // 每帧分别计数，允许一次 read 包含多个合法消息。
        let segments = data.split(separator: 10, omittingEmptySubsequences: false)
        for segment in segments.enumerated() {
            bytes.append(contentsOf: segment.element)
            guard bytes.count + 1 <= 1024 * 1024 else { fail(PluginSessionError.messageTooLarge); return }
            if segment.offset < segments.count - 1 {
                guard let message = try? JSONDecoder().decode(PluginMessage.self, from: bytes), message.protocolVersion == 1 else {
                    fail(PluginSessionError.invalidMessage); return
                }
                bytes.removeAll(keepingCapacity: true)
                receive(message)
                if closed { return }
            }
        }
    }

    private func receive(_ message: PluginMessage) {
        if message.type == "ready", !ready, message.id == "ready" {
            ready = true
            for request in Array(pending.values) {
                if request.cancellation?.isCancelled == true {
                    finish(request.message.id, result: .failure(PluginSessionError.cancelled))
                } else { send(request.message) }
            }
            return
        }
        guard ready else { fail(PluginSessionError.invalidMessage); return }
        if shuttingDown {
            if message.id == sessionID + "/exit", message.type == "result" { finishClose() }
            return
        }
        if message.type == "call" {
            guard !shuttingDown, let method = message.method, let params = message.params,
                  hostTasks[message.id] == nil, hostTasks.count < 16, message.id.hasPrefix("host-") else {
                fail(PluginSessionError.invalidMessage); return
            }
            let handler = hostCall
            hostTasks[message.id] = Task { [weak self] in
                let result: Result<PluginValue, any Error>
                do { result = .success(try await handler(method, params)) } catch { result = .failure(error) }
                guard let self else { return }
                self.queue.async {
                    self.hostTasks.removeValue(forKey: message.id)
                    guard !self.closed, !self.shuttingDown else { return }
                    switch result {
                    case let .success(value):
                        let didReply = self.onHostReply
                        self.send(PluginMessage(type: "result", id: message.id, value: value)) { didReply(method) }
                    case let .failure(error): self.send(PluginMessage(type: "result", id: message.id, error: error.localizedDescription))
                    }
                }
            }
            return
        }
        guard let request = pending[message.id] else { fail(PluginSessionError.invalidMessage); return }
        if message.type == "list", request.message.method == "input", let value = message.value {
            do {
                let items = try PluginListItem.decode(value)
                if request.cancellation?.isCancelled != true { request.listUpdate?(items) }
            } catch { fail(error) }
        } else if message.type == "result" {
            if let error = message.error { finish(message.id, result: .failure(PluginSessionError.plugin(error))) }
            else if let value = message.value { finish(message.id, result: .success(value)) }
            else { fail(PluginSessionError.invalidMessage) }
        } else { fail(PluginSessionError.invalidMessage) }
    }

    private func finish(_ id: String, result: Result<PluginValue, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if let observation = request.observation { request.cancellation?.removeObserver(observation) }
        if request.cancellation?.isCancelled == true { request.continuation.resume(throwing: PluginSessionError.cancelled) }
        else { request.continuation.resume(with: result) }
    }

    private func resumePending(_ error: any Error) {
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        logger.error("插件会话失败：\(error.localizedDescription)。")
        resumePending(error)
        finishClose()
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        resumePending(PluginSessionError.closed)
        for task in hostTasks.values { task.cancel() }
        hostTasks.removeAll()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // 先终止读端，阻塞的写操作才能退出；关闭写句柄由同一写队列完成。
        let inputHandle = input.fileHandleForWriting
        writer.async { try? inputHandle.close() }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            // 用户脚本可能忽略 SIGTERM；最终强制结束，且不靠循环轮询进程。
            let runningProcess = process
            queue.asyncAfter(deadline: .now() + 0.25) {
                if runningProcess.isRunning { kill(runningProcess.processIdentifier, SIGKILL) }
            }
        }
        logger.debug("已释放插件会话。")
    }
}
