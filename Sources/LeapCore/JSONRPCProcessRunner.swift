import Foundation
import OSLog

struct JSONRPCRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: Parameters

    struct Parameters: Codable, Equatable, Sendable {
        let commandID: String
        let query: String
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

        public var errorDescription: String? {
            switch self {
            case .timedOut: "插件响应超时。"
            case .invalidResponse: "插件返回了无效的 JSON-RPC 响应。"
            case .mismatchedResponseID: "插件响应与当前请求不匹配。"
            case let .pluginError(message): "插件执行失败：\(message)"
            case let .processFailed(status, message): "插件进程异常退出（\(status)）：\(message)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.padding.leap", category: "json-rpc")

    public init() {}

    public func invoke(
        executable: URL,
        arguments: [String],
        commandID: String,
        query: String,
        timeout: TimeInterval = 3
    ) throws -> String {
        let request = JSONRPCRequest(
            id: UUID().uuidString,
            method: "leap.invoke",
            params: .init(commandID: commandID, query: query)
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

        try process.run()
        let requestData = try JSONEncoder().encode(request) + Data([0x0A])
        input.fileHandleForWriting.write(requestData)
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            throw RunnerError.timedOut
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

        Self.logger.debug("插件 JSON-RPC 请求已完成：\(commandID, privacy: .public)。")
        return result
    }
}
