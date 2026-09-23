import Foundation

public struct RecentCommandKey: Codable, Hashable, Sendable {
    public let pluginID: String
    public let commandID: String

    public init(pluginID: String, commandID: String) {
        self.pluginID = pluginID
        self.commandID = commandID
    }
}

public final class RecentCommandStore {
    private let defaults: UserDefaults
    private let key: String
    private let maximumCount: Int

    public init(defaults: UserDefaults = .standard, key: String = "recentCommandKeys", maximumCount: Int = 8) {
        self.defaults = defaults
        self.key = key
        self.maximumCount = maximumCount
    }

    public func load(validKeys: Set<RecentCommandKey>) -> [RecentCommandKey] {
        let keys = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([RecentCommandKey].self, from: $0) } ?? []
        let current = keys.filter(validKeys.contains)
        if current != keys {
            save(current)
        }
        return current
    }

    public func record(_ command: RecentCommandKey, validKeys: Set<RecentCommandKey>) {
        let updated = ([command] + load(validKeys: validKeys).filter { $0 != command }).prefix(maximumCount)
        save(Array(updated))
    }

    private func save(_ keys: [RecentCommandKey]) {
        guard let data = try? JSONEncoder().encode(keys) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

public enum LauncherUsageKey: Codable, Hashable, Sendable {
    case application(path: String)
    case plugin(RecentCommandKey)
}

public struct LauncherUsageRecord: Codable, Hashable, Sendable {
    public let key: LauncherUsageKey
    public let lastUsed: Date
    public let launchCount: Int

    public init(key: LauncherUsageKey, lastUsed: Date = .now, launchCount: Int = 1) {
        self.key = key
        self.lastUsed = lastUsed
        self.launchCount = launchCount
    }
}

/// 应用与插件共用同一份最近使用记录；旧插件记录仅在首次读取时迁移。
public final class LauncherUsageStore {
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String
    private let maximumCount: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "launcherUsageRecords",
        legacyKey: String = "recentCommandKeys",
        maximumCount: Int = 8
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
        self.maximumCount = maximumCount
    }

    public func load(validKeys: Set<LauncherUsageKey>) -> [LauncherUsageRecord] {
        let records = storedRecords()
        let current = records.filter { validKeys.contains($0.key) }
        if current != records { save(current) }
        return current
    }

    public func record(_ key: LauncherUsageKey, validKeys: Set<LauncherUsageKey>) {
        let previous = load(validKeys: validKeys).first(where: { $0.key == key })
        let record = LauncherUsageRecord(
            key: key,
            lastUsed: .now,
            launchCount: (previous?.launchCount ?? 0) + 1
        )
        save(Array(([record] + load(validKeys: validKeys).filter { $0.key != key }).prefix(maximumCount)))
    }

    /// 同时清除旧键，避免下次读取时将历史记录重新迁移回来。
    public func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private func storedRecords() -> [LauncherUsageRecord] {
        if let data = defaults.data(forKey: key),
           let records = try? JSONDecoder().decode([LauncherUsageRecord].self, from: data) {
            return records
        }

        let legacy = defaults.data(forKey: legacyKey)
            .flatMap { try? JSONDecoder().decode([RecentCommandKey].self, from: $0) } ?? []
        let now = Date.now
        let migrated = legacy.enumerated().map {
            LauncherUsageRecord(
                key: .plugin($0.element),
                lastUsed: now.addingTimeInterval(-Double($0.offset)),
                launchCount: 1
            )
        }
        if !migrated.isEmpty { save(migrated) }
        return migrated
    }

    private func save(_ records: [LauncherUsageRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
