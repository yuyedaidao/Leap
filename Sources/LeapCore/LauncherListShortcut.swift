import AppKit

/// 两种列表共用数字映射；窗口负责焦点、输入法和弹窗检查。
public enum LauncherListShortcut {
    public static func index(for key: String, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .shift, .option, .control]) == .command,
              key.utf8.count == 1, let digit = Int(key), (0...9).contains(digit) else { return nil }
        return digit == 0 ? 9 : digit - 1
    }

    public static func hint(at index: Int) -> String? {
        guard (0..<10).contains(index) else { return nil }
        return "⌘\(index == 9 ? 0 : index + 1)"
    }
}
