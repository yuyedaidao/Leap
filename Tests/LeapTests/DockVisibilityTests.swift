import AppKit
import Foundation
import Testing

@testable import LeapCore

struct DockVisibilityTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LeapDockVisibility-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("未写过时默认显示图标，写入后按新值读到并持久化")
    func persistence() {
        let defaults = makeDefaults()
        let store = DockVisibility(defaults: defaults)
        #expect(store.isEnabled)

        store.setEnabled(false)
        #expect(!store.isEnabled)
        #expect(!DockVisibility(defaults: defaults).isEnabled)

        store.setEnabled(true)
        #expect(DockVisibility(defaults: defaults).isEnabled)
    }

    @Test("开关映射到激活策略：显示走 regular，隐藏走无程序坞图标的 accessory")
    func activationPolicy() {
        #expect(DockVisibility.activationPolicy(isEnabled: true) == .regular)
        #expect(DockVisibility.activationPolicy(isEnabled: false) == .accessory)
    }
}
