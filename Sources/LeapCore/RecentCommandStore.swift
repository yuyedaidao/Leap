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
