import AppKit

/// 记录是否在程序坞显示图标；从未写过时保持既有行为（显示）。
public final class DockVisibility {
    public static let defaultKey = "showsDockIcon"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = DockVisibility.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public var isEnabled: Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }

    /// 关闭开关时用 `.accessory`：图标连同 ⌘Tab 条目、菜单栏一起退出，只保留全局快捷键入口。
    public static func activationPolicy(isEnabled: Bool) -> NSApplication.ActivationPolicy {
        isEnabled ? .regular : .accessory
    }
}
