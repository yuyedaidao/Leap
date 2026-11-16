import Foundation
import LeapCore

/// 复用池内会话时，脚本的宿主调用必须转到「当前」交互，而不是当初创建它的那一次。
@MainActor
final class PluginHostRouter {
    weak var session: PluginInteractionSession?

    func handle(_ method: String, params: PluginValue) async throws -> PluginValue {
        guard let session, session.isActive else { throw PluginSessionError.closed }
        return try await session.handleHostCall(method, params: params)
    }

    /// 宿主回完后把方法名回传当前会话：hideMainWindow/runPlugin 等靠这个回执收尾。
    nonisolated func reply(_ method: String) {
        Task { @MainActor in session?.didReplyHostCall(method) }
    }
}

/// 交互插件关闭后保留 Node 进程一小段时间：再次打开省掉冷启，超时后回收。
/// TTL 取 180s，与 uTools 的 `pluginOutTimer` 默认值一致。
@MainActor
final class PluginSessionPool {
    struct Key: Hashable {
        let pluginID: String
        let commandID: String
    }

    final class Session {
        let router: PluginHostRouter
        let script: PluginScriptSession

        init(router: PluginHostRouter, script: PluginScriptSession) {
            self.router = router
            self.script = script
        }
    }

    private struct Entry {
        let session: Session
        let snapshot: PluginListSnapshot?
        let expiry: Task<Void, Never>
    }

    private let lifetime: Duration
    private var entries: [Key: Entry] = [:]

    init(lifetime: Duration = .seconds(180)) { self.lifetime = lifetime }

    /// 取走空闲会话（含它上次的列表快照），过期回收交给后台任务。
    func borrow(_ key: Key) -> (session: Session, snapshot: PluginListSnapshot?)? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        entry.expiry.cancel()
        return (entry.session, entry.snapshot)
    }

    func recycle(_ session: Session, snapshot: PluginListSnapshot?, for key: Key) {
        session.router.session = nil
        // 预热窗口内用户已先开会话时，池里可能已有同 key 的 entry，覆盖前先关掉，避免残留两个 Node 进程。
        if let existing = entries.removeValue(forKey: key) {
            existing.expiry.cancel()
            existing.session.script.close()
        }
        let lifetime = lifetime
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.evict(key, session: session)
        }
        entries[key] = Entry(session: session, snapshot: snapshot, expiry: expiry)
    }

    /// 宿主启动后预热，把首次打开的冷启代价挪到空闲时。
    func prewarm(_ key: Key, executor: PluginScriptExecutor, manifest: PluginManifest, pluginDirectory: URL) {
        guard entries[key] == nil else { return }
        do {
            let session = try makeSession(executor: executor, manifest: manifest, pluginDirectory: pluginDirectory,
                                          commandID: key.commandID, query: "")
            // 只构造不算预热：Node 进程要 start() 才真正拉起。
            Task { [weak self] in
                do {
                    try await session.script.start()
                } catch {
                    // start 失败会缓存失败的 enter，入池后每次复用都复读同一错误，直接关掉。
                    session.script.close()
                    return
                }
                guard let self else { return }
                guard entries[key] == nil else {
                    session.script.close()  // 用户已先行打开，这个预热进程没有归属
                    return
                }
                recycle(session, snapshot: nil, for: key)
            }
        } catch {
            // 预热只是优化，失败时按普通路径重新创建。
        }
    }

    func closeAll() {
        for entry in entries.values {
            entry.expiry.cancel()
            entry.session.script.close()
        }
        entries.removeAll()
    }

    func makeSession(executor: PluginScriptExecutor, manifest: PluginManifest, pluginDirectory: URL,
                     commandID: String, query: String) throws -> Session {
        let router = PluginHostRouter()
        let script = try executor.makeSession(
            manifest: manifest, pluginDirectory: pluginDirectory, commandID: commandID, query: query,
            hostCall: { method, params in try await router.handle(method, params: params) },
            onHostReply: { [weak router] method in router?.reply(method) }
        )
        return Session(router: router, script: script)
    }

    private func evict(_ key: Key, session: Session) {
        guard entries[key]?.session === session else { return }
        entries.removeValue(forKey: key)
        session.script.close()
    }
}
