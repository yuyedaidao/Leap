import Foundation

public struct RemotePluginHTTPResponse: Sendable {
    public let file: URL
    public let status: Int
    public let headers: [String: String]

    public init(file: URL, status: Int, headers: [String: String] = [:]) {
        self.file = file
        self.status = status
        self.headers = headers
    }
}

public protocol RemotePluginHTTPClient: Sendable {
    /// 返回独立临时文件，调用方在读取或移动后负责清理。
    func download(_ url: URL, maximumBytes: Int) async throws -> RemotePluginHTTPResponse
}

public struct GitHubPluginHTTPClient: RemotePluginHTTPClient {
    public init() {}

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && ["api.github.com", "raw.githubusercontent.com"].contains(url.host ?? "")
            && url.user == nil && url.password == nil && url.port == nil
    }

    public func download(_ url: URL, maximumBytes: Int) async throws -> RemotePluginHTTPResponse {
        guard Self.isAllowed(url) else { throw RemotePluginError.unsafeRedirect }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Leap-Plugin-Installer", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let redirectGuard = GitHubRedirectGuard()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch {
            if redirectGuard.didReject { throw RemotePluginError.unsafeRedirect }
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw RemotePluginError.incompleteDownload }
        // 错误响应只需状态与响应头，避免小文件的错误页被误报为体积超限。
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        if response.statusCode != 200 && response.statusCode != 422 {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("LeapHTTP-\(UUID().uuidString)")
            try Data().write(to: file)
            return RemotePluginHTTPResponse(file: file, status: response.statusCode, headers: headers)
        }
        guard response.expectedContentLength <= maximumBytes else {
            throw RemotePluginError.limitExceeded("响应体积")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LeapHTTP-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var keepFile = false
        defer { if !keepFile { try? FileManager.default.removeItem(at: file) } }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var count = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumBytes else { throw RemotePluginError.limitExceeded("响应体积") }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        try Task.checkCancellation()
        keepFile = true
        return RemotePluginHTTPResponse(file: file, status: response.statusCode, headers: headers)
    }
}

final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    var didReject: Bool { lock.withLock { rejected } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 拒绝跳转时取消任务，不能把重定向响应当作插件文件。
        guard let url = request.url, GitHubPluginHTTPClient.isAllowed(url) else {
            lock.withLock { rejected = true }
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
