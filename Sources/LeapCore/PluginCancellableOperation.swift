import Foundation

/// 系统授权或 Apple Events 未必响应 Task.cancel；调用者必须能先结束等待。
enum PluginCancellableOperation {
    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var result: Result<Value, any Error>?

        func install(_ value: CheckedContinuation<Value, any Error>) {
            let ready: Result<Value, any Error>? = lock.withLock {
                if let result { return result }
                continuation = value
                return nil as Result<Value, any Error>?
            }
            if let ready { value.resume(with: ready) }
        }

        func finish(_ value: Result<Value, any Error>) {
            let pending = lock.withLock {
                guard result == nil else { return nil as CheckedContinuation<Value, any Error>? }
                result = value
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: value)
        }
    }

    static func value<Value: Sendable>(of task: Task<Value, any Error>) async throws -> Value {
        let completion = Completion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                Task {
                    do {
                        completion.finish(.success(try await task.value))
                    } catch { completion.finish(.failure(error)) }
                }
            }
        } onCancel: {
            task.cancel()
            completion.finish(.failure(CancellationError()))
        }
    }
}
