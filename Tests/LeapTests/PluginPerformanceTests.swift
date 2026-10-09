import Foundation
import Observation
import Testing
@testable import LeapCore

@MainActor
struct PluginPerformanceTests {
    @Test("数字枚举暖态包含输入合并和主线程发布的 p95 在 50ms 内")
    func warmInputLatency() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Examples/Plugins/NumberEnumeration")
        let manifest = try PluginManifestValidator().load(from: directory)
        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent(".test-support"),
                             resourceDirectory: root.appendingPathComponent("Resources/Leap"))
        let script = try PluginScriptExecutor(runtimeLocator: BundledRuntimeLocator(paths: paths))
            .makeSession(manifest: manifest, pluginDirectory: directory, commandID: "number.enumerate", query: "")
        defer { script.close() }
        let list = PluginListSession { method, query, itemID, cancellation, update in
            try await script.call(method, query: query, itemID: itemID, cancellation: cancellation, onList: update)
        }
        defer { list.close() }
        let cold = try await ListQueryMeasurement(list: list, query: "1").measure()
        var samples: [Double] = []
        for index in 0..<100 {
            let query = index.isMultiple(of: 2) ? "2" : "1"
            // 1 和 2 都有“标题 0”，测量必须同时等待加载完成，不能只看到上次条目就结束。
            samples.append(try await ListQueryMeasurement(list: list, query: query).measure())
        }
        samples.sort()
        print("Leap SDK benchmark cold=\(cold)ms p50=\(samples[49])ms p95=\(samples[94])ms samples=100")
        #expect(samples[94] < 50)
    }
}

@MainActor
private final class ListQueryMeasurement {
    private let list: PluginListSession
    private let query: String
    private var continuation: CheckedContinuation<Double, any Error>?
    private var timeout: Task<Void, Never>?
    private let start = ContinuousClock.now

    init(list: PluginListSession, query: String) { self.list = list; self.query = query }

    func measure() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            list.updateInput(query)
            observe()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                self.continuation?.resume(throwing: PluginSessionError.timedOut)
                self.continuation = nil
            }
        }
    }

    private func observe() {
        guard let continuation else { return }
        if !list.isLoading {
            if list.isError {
                continuation.resume(throwing: PluginSessionError.plugin(list.message ?? "查询失败"))
            } else {
                let duration = start.duration(to: .now).components
                continuation.resume(returning: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
            self.continuation = nil
            timeout?.cancel()
            return
        }
        withObservationTracking { _ = list.isLoading; _ = list.isError } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
}
