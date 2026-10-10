import Foundation
import Observation
import YQLogger

/// 跨主线程与脚本工作线程传递取消，不把 Task.cancel 误认为进程已经终止。
public final class PluginInvocationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        let callbacks = lock.withLock {
            cancelled = true
            return Array(observers.values)
        }
        callbacks.forEach { $0() }
    }
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let notify = lock.withLock { observers[id] = callback; return cancelled }
        if notify { callback() }
        return id
    }
    public func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
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

    public static func decode(_ value: PluginValue) throws -> [Self] {
        guard case let .array(values) = value, values.count <= 100 else {
            throw ListError.invalidResult
        }
        // 消息大小已在进程边界限制；直接读取结构化值，避免每批列表再编码和解码 JSON。
        var identifiers = Set<String>()
        return try values.map { value in
            guard case let .object(fields) = value,
                  let id = fields["id"]?.string, !id.isEmpty,
                  let title = fields["title"]?.string, !title.isEmpty,
                  identifiers.insert(id).inserted,
                  fields["description"] == nil || fields["description"] == .null ||
                    fields["description"]?.string != nil else {
                throw ListError.invalidResult
            }
            return Self(id: id, title: title, description: fields["description"]?.string)
        }
    }

    public enum ListError: LocalizedError {
        case invalidResult
        public var errorDescription: String? { "插件列表无效：最多100项，条目标识须非空且唯一，标题须非空。" }
    }
}

/// 标题和条目属于同一查询快照，避免分批发布时串到另一批结果。
public struct PluginListSnapshot: Equatable, Sendable {
    public let items: [PluginListItem]
    public let title: String?

    public init(items: [PluginListItem], title: String? = nil) {
        self.items = items
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title : nil
    }

    public static func decode(_ value: PluginValue) throws -> Self {
        if case .array = value { return Self(items: try PluginListItem.decode(value)) }
        guard case let .object(fields) = value, let items = fields["items"],
              fields["title"] == nil || fields["title"]?.string != nil else {
            throw PluginListItem.ListError.invalidResult
        }
        return Self(items: try PluginListItem.decode(items), title: fields["title"]?.string)
    }
}

@MainActor
@Observable
public final class PluginListSession {
    @MainActor private final class QueryDelivery { var finished = false }
    public typealias Call = @Sendable (String, String, String?, PluginInvocationCancellation,
                                      @escaping PluginProcessSession.ListUpdate) async throws -> PluginValue
    public private(set) var snapshot = PluginListSnapshot(items: [])
    public var items: [PluginListItem] { snapshot.items }
    public var title: String? { snapshot.title }
    public private(set) var selectedID: String?
    public private(set) var isLoading = false
    public private(set) var isSelecting = false
    public private(set) var isLoadingVisible = false
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

    public init(debounce: Duration = .milliseconds(16), call: @escaping Call) {
        self.debounce = debounce
        self.call = call
    }

    public func updateInput(_ text: String) {
        guard isActive else { return }
        input = text
        revision &+= 1
        debounceTask?.cancel()
        if !isSelecting {
            isLoadingVisible = false
            cancellation?.cancel()
        }
        queryReady = false
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

    /// 仅接受当前回调的显式加载请求；结束、取消及旧回调的迟到消息均不可重启动画。
    public func setLoading(_ visible: Bool, cancellation token: PluginInvocationCancellation) {
        guard isActive, cancellation === token, (!visible || !token.isCancelled), queryRunning || isSelecting else { return }
        isLoadingVisible = visible
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
            do { response = .success(try await call("select", query, item.id, token, { _ in }).string ?? "") } catch {
                response = .failure(error)
            }
            guard let self, isActive else { return }
            isSelecting = false
            isLoadingVisible = false
            if version == revision { display(response) }
            startQueryIfReady()
        }
    }

    @discardableResult
    public func select(at index: Int, isRepeat: Bool = false) -> Bool {
        guard isActive, (0..<10).contains(index), items.indices.contains(index) else { return false }
        // 加载时仍消费有效数字键，但不排队执行旧条目。
        if !isRepeat { select(items[index].id) }
        return true
    }

    public func close() {
        isActive = false
        isLoadingVisible = false
        revision &+= 1
        debounceTask?.cancel()
        cancellation?.cancel()
        snapshot = PluginListSnapshot(items: [])
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
            let response: Result<PluginListSnapshot, Error>
            let session = self
            let delivery = QueryDelivery()
            do {
                let result = try await call("input", query, nil, token) { values in
                    Task { @MainActor [weak self = session] in
                        guard let self, !delivery.finished, self.isActive, self.revision == version else { return }
                        self.apply(values)
                    }
                }
                response = .success(try PluginListSnapshot.decode(result))
            } catch { response = .failure(error) }
            delivery.finished = true
            guard let self, isActive else { return }
            queryRunning = false
            isLoadingVisible = false
            // 版本号检查仍需保留：插件可能在取消前已经完成，或测试调用不响应取消。
            if revision == version {
                isLoading = false
                switch response {
                case let .success(values):
                    // 最终快照与加载完成一起发布；迟到的分批更新不能把最终结果改回旧批次。
                    apply(values)
                case let .failure(error):
                    display(.failure(error))
                }
            }
            startQueryIfReady()
        }
    }

    private func apply(_ value: PluginListSnapshot) {
        guard snapshot != value else { return }
        let previous = selectedID
        snapshot = value
        selectedID = items.contains(where: { $0.id == previous }) ? previous : items.first?.id
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
