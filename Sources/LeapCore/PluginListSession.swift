import Foundation
import Observation
import YQLogger

/// 跨主线程与脚本工作线程传递取消，不把 Task.cancel 误认为进程已经终止。
public final class PluginInvocationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

public struct PluginListItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?

    public init(id: String, title: String, description: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
    }

    public static func decode(_ text: String) throws -> [Self] {
        struct Result: Decodable { let items: [PluginListItem] }
        guard text.utf8.count <= 1024 * 1024,
              let result = try? JSONDecoder().decode(Result.self, from: Data(text.utf8)),
              result.items.count <= 100,
              Set(result.items.map(\.id)).count == result.items.count,
              result.items.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }) else {
            throw ListError.invalidResult
        }
        return result.items
    }

    public enum ListError: LocalizedError {
        case invalidResult
        public var errorDescription: String? { "插件列表无效：最多100项，条目标识须非空且唯一，标题须非空。" }
    }
}

@MainActor
@Observable
public final class PluginListSession {
    public typealias Call = @Sendable (String, String, String?, PluginInvocationCancellation) async throws -> String
    public private(set) var items: [PluginListItem] = []
    public private(set) var selectedID: String?
    public private(set) var isLoading = false
    public private(set) var isSelecting = false
    public private(set) var message: String?
    public private(set) var isError = false
    public private(set) var input = ""

    private let call: Call
    private let debounce: Duration
    private var revision = 0
    private var isActive = true
    private var debounceTask: Task<Void, Never>?
    private var cancellation: PluginInvocationCancellation?
    private var queryRunning = false
    private var queryReady = false

    public init(debounce: Duration = .milliseconds(200), call: @escaping Call) {
        self.debounce = debounce
        self.call = call
    }

    public func updateInput(_ text: String) {
        guard isActive else { return }
        input = text
        revision &+= 1
        debounceTask?.cancel()
        if !isSelecting { cancellation?.cancel() }
        queryReady = false
        items = []
        selectedID = nil
        message = nil
        isError = false
        isLoading = true
        debounceTask = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, isActive else { return }
            queryReady = true
            startQueryIfReady()
        }
    }

    public func moveSelection(_ offset: Int) {
        guard !items.isEmpty, !isSelecting else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(current + offset, 0), items.count - 1)].id
    }

    public func select(_ id: String? = nil) {
        guard isActive, !isLoading, !isSelecting,
              let item = items.first(where: { $0.id == (id ?? selectedID) }) else { return }
        selectedID = item.id
        isSelecting = true
        let version = revision
        let query = input
        let token = PluginInvocationCancellation()
        cancellation = token
        Task { [weak self, call] in
            let response: Result<String, Error>
            do { response = .success(try await call("leap.select", query, item.id, token)) } catch { response = .failure(error) }
            guard let self, isActive else { return }
            isSelecting = false
            if version == revision { display(response) }
            startQueryIfReady()
        }
    }

    public func close() {
        isActive = false
        revision &+= 1
        debounceTask?.cancel()
        cancellation?.cancel()
        items = []
        selectedID = nil
    }

    private func startQueryIfReady() {
        guard isActive, queryReady, !queryRunning, !isSelecting else { return }
        queryReady = false
        queryRunning = true
        let version = revision
        let query = input
        let token = PluginInvocationCancellation()
        cancellation = token
        Task { [weak self, call] in
            let response: Result<[PluginListItem], Error>
            do { response = .success(try PluginListItem.decode(await call("leap.query", query, nil, token))) } catch { response = .failure(error) }
            guard let self, isActive else { return }
            queryRunning = false
            // 版本号检查仍需保留：插件可能在取消前已经完成，或测试调用不响应取消。
            if revision == version {
                isLoading = false
                switch response {
                case let .success(values):
                    items = values
                    selectedID = values.first?.id
                case let .failure(error):
                    display(.failure(error))
                }
            }
            startQueryIfReady()
        }
    }

    private func display(_ response: Result<String, Error>) {
        switch response {
        case let .success(text):
            message = text
            isError = false
        case let .failure(error):
            message = error.localizedDescription
            isError = true
            YQLogger(label: "com.padding.leap/plugin-list").error("插件列表调用失败：\(error.localizedDescription)。")
        }
    }
}
