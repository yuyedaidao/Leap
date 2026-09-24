import Foundation
@preconcurrency import YQLogger

public enum ShellScriptError: LocalizedError, Equatable {
    case invalidEntry
    case shellUnavailable
    case notStarted
    case cancelled
    case processFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEntry: "Shell 脚本入口必须位于受管插件目录内。"
        case .shellUnavailable: "系统 zsh 运行时不可用。"
        case .notStarted: "Shell 脚本尚未启动。"
        case .cancelled: "Shell 脚本已停止。"
        case let .processFailed(status): "Shell 脚本异常退出（\(status)）。"
        }
    }
}

/// 单次 Shell 调用；输出通过 Pipe 增量回调，避免前台命令结束前没有任何可见反馈。
public final class ShellScriptTask: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let entryURL: URL
    private let pluginDirectory: URL
    private let commandID: String
    private let stateLock = NSLock()
    private var started = false
    private var cancelled = false

    init(entryURL: URL, pluginDirectory: URL, commandID: String) throws {
        let standardizedDirectory = pluginDirectory.standardizedFileURL
        let standardizedEntry = entryURL.standardizedFileURL
        guard standardizedEntry.path.hasPrefix(standardizedDirectory.path + "/") else {
            throw ShellScriptError.invalidEntry
        }
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw ShellScriptError.shellUnavailable
        }
        self.entryURL = standardizedEntry
        self.pluginDirectory = standardizedDirectory
        self.commandID = commandID
    }

    public func start(onOutput: @escaping @Sendable (String) -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { return }
        started = true

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            onOutput(String(decoding: data, as: UTF8.self))
        }
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [entryURL.path]
        process.currentDirectoryURL = pluginDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["LEAP_COMMAND_ID"] = commandID
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    public func waitForCompletion(onOutput: @escaping @Sendable (String) -> Void) throws {
        stateLock.lock()
        let didStart = started
        stateLock.unlock()
        guard didStart else { throw ShellScriptError.notStarted }

        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        output.fileHandleForReading.readabilityHandler = nil
        let remainingOutput = output.fileHandleForReading.readDataToEndOfFile()
        if !remainingOutput.isEmpty {
            onOutput(String(decoding: remainingOutput, as: UTF8.self))
        }

        stateLock.lock()
        let wasCancelled = cancelled
        stateLock.unlock()
        if wasCancelled { throw ShellScriptError.cancelled }
        guard process.terminationStatus == 0 else {
            throw ShellScriptError.processFailed(process.terminationStatus)
        }
    }

    public func cancel() {
        stateLock.lock()
        cancelled = true
        let isRunning = process.isRunning
        stateLock.unlock()
        if isRunning { process.terminate() }
    }
}

public final class ShellScriptExecutor: @unchecked Sendable {
    private static let logger = YQLogger(label: "com.padding.leap/shell-script")
    private let backgroundLock = NSLock()
    private var backgroundTasks: [UUID: ShellScriptTask] = [:]

    public init() {}

    public func makeForegroundTask(
        entryURL: URL,
        pluginDirectory: URL,
        commandID: String
    ) throws -> ShellScriptTask {
        try ShellScriptTask(entryURL: entryURL, pluginDirectory: pluginDirectory, commandID: commandID)
    }

    public func startBackground(entryURL: URL, pluginDirectory: URL, commandID: String) throws {
        let task = try makeForegroundTask(
            entryURL: entryURL,
            pluginDirectory: pluginDirectory,
            commandID: commandID
        )
        let taskID = UUID()
        backgroundLock.lock()
        backgroundTasks[taskID] = task
        backgroundLock.unlock()

        do {
            try task.start(onOutput: { _ in })
        } catch {
            removeBackgroundTask(taskID)
            throw error
        }

        DispatchQueue.global(qos: .utility).async { [weak self, task] in
            do {
                try task.waitForCompletion(onOutput: { _ in })
            } catch {
                Self.logger.error("后台 Shell 脚本失败：\(error.localizedDescription)。")
            }
            self?.removeBackgroundTask(taskID)
        }
    }

    private func removeBackgroundTask(_ taskID: UUID) {
        backgroundLock.lock()
        backgroundTasks.removeValue(forKey: taskID)
        backgroundLock.unlock()
    }
}
