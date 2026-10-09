import Darwin
import Foundation
@preconcurrency import YQLogger

struct JSONRPCRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: Parameters

    struct Parameters: Codable, Equatable, Sendable {
        let commandID: String
        let query: String
        let itemID: String?

        init(commandID: String, query: String, itemID: String? = nil) {
            self.commandID = commandID
            self.query = query
            self.itemID = itemID
        }
    }

    init(id: String, method: String, params: Parameters) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: String
    let result: String?
    let error: ErrorPayload?

    struct ErrorPayload: Codable, Equatable, Sendable {
        let code: Int
        let message: String
    }
}

public struct JSONRPCProcessRunner: Sendable {
    public enum RunnerError: LocalizedError, Equatable {
        case timedOut
        case invalidResponse
        case mismatchedResponseID
        case pluginError(String)
        case processFailed(Int32, String)
        case cancelled
        case responseTooLarge

        public var errorDescription: String? {
            switch self {
            case .timedOut: "插件响应超时。"
            case .invalidResponse: "插件返回了无效的 JSON-RPC 响应。"
            case .mismatchedResponseID: "插件响应与当前请求不匹配。"
            case let .pluginError(message): "插件执行失败：\(message)"
            case let .processFailed(status, message): "插件进程异常退出（\(status)）：\(message)"
            case .cancelled: "插件查询已取消。"
            case .responseTooLarge: "插件请求或响应超过1MB限制。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/json-rpc")

    public init() {}

    public func invoke(
        executable: URL,
        arguments: [String],
        commandID: String,
        query: String,
        timeout: TimeInterval = 3,
        method: String = "leap.invoke",
        itemID: String? = nil,
        cancellation: PluginInvocationCancellation? = nil
    ) throws -> String {
        let request = JSONRPCRequest(
            id: UUID().uuidString,
            method: method,
            params: .init(commandID: commandID, query: query, itemID: itemID)
        )
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        // 查询列表可能超过管道缓冲区；执行期间持续排空，避免等待退出与输出写入互相阻塞。
        let outputBuffer = ProcessOutputBuffer(limit: 1024 * 1024)
        let errorBuffer = ProcessOutputBuffer(limit: 64 * 1024)
        output.fileHandleForReading.readabilityHandler = { outputBuffer.readAvailable($0) }
        error.fileHandleForReading.readabilityHandler = { errorBuffer.readAvailable($0) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        guard cancellation?.isCancelled != true else { throw RunnerError.cancelled }
        let requestData = try JSONEncoder().encode(request) + Data([0x0A])
        guard requestData.count <= 1024 * 1024 else { throw RunnerError.responseTooLarge }
        // 取消会关闭读端；让写入返回 EPIPE，而非通过 SIGPIPE 终止整个宿主。
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        // 插件可能不读取标准输入；写入不能阻塞监控线程，否则超时与取消都无法生效。
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? input.fileHandleForWriting.close() }
            do { try input.fileHandleForWriting.write(contentsOf: requestData) } catch {
                Self.logger.debug("插件输入管道已关闭：\(error.localizedDescription)。")
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if cancellation?.isCancelled == true {
                throw RunnerError.cancelled
            }
            guard !outputBuffer.exceededLimit else { throw RunnerError.responseTooLarge }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            throw RunnerError.timedOut
        }

        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        outputBuffer.finish(output.fileHandleForReading)
        errorBuffer.finish(error.fileHandleForReading)
        guard !outputBuffer.exceededLimit else { throw RunnerError.responseTooLarge }
        let outputData = outputBuffer.data
        let errorText = String(decoding: errorBuffer.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RunnerError.processFailed(process.terminationStatus, errorText)
        }

        guard let responseData = outputData.split(separator: 0x0A).first,
              let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: responseData),
              response.jsonrpc == "2.0" else {
            throw RunnerError.invalidResponse
        }
        guard response.id == request.id else {
            throw RunnerError.mismatchedResponseID
        }
        if let error = response.error {
            throw RunnerError.pluginError(error.message)
        }
        guard let result = response.result else {
            throw RunnerError.invalidResponse
        }

        Self.logger.debug("插件 JSON-RPC 请求已完成：\(commandID)。")
        return result
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false
    init(limit: Int) { self.limit = limit }
    var data: Data { lock.withLock { storage } }
    var exceededLimit: Bool { lock.withLock { exceeded } }
    func readAvailable(_ handle: FileHandle) {
        lock.withLock { append(handle.availableData) }
    }
    func finish(_ handle: FileHandle) {
        lock.withLock { append(handle.readDataToEndOfFile()) }
    }
    private func append(_ data: Data) {
        if storage.count + data.count > limit { exceeded = true }
        storage.append(data.prefix(max(0, limit - storage.count)))
    }
}
