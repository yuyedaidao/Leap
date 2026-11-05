import Foundation

/// 记录被禁用的插件 id；集合为空表示全部启用。
public final class PluginEnabledStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "disabledPluginIDs") {
        self.defaults = defaults
        self.key = key
    }

    public func isEnabled(pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID)
    }

    public func setEnabled(_ enabled: Bool, pluginID: String) {
        var identifiers = disabledPluginIDs
        let changed = enabled ? identifiers.remove(pluginID) != nil : identifiers.insert(pluginID).inserted
        guard changed else { return }
        defaults.set(identifiers.sorted(), forKey: key)
    }

    public var disabledPluginIDs: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
