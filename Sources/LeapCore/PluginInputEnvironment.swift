import AppKit
import Foundation

/// 隔离真实键盘与前台应用，回归测试不会向用户正在使用的窗口发送输入。
@MainActor
struct PluginInputEnvironment {
    var frontmostPID: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var isAlive: (Int32) -> Bool = { pid in
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }
    var activate: (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activate() ?? false }
    var requirePermission: () throws -> Void = { try PluginKeyboard.requirePermission() }
    var paste: () throws -> Void = { try PluginKeyboard.tap(9, flags: .maskCommand) }
    var type: ([UInt16]) throws -> Void = { try PluginKeyboard.type($0) }
}
