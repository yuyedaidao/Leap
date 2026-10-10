import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// 键名对应 macOS 虚拟键码；文本输入另外使用 Unicode，不受键盘布局影响。
public enum PluginKeyboard {
    private static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "enter": 36, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, " ": 49,
        "`": 50, "backspace": 51, "escape": 53, "esc": 53, "delete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90
    ]

    public static func decode(_ key: String, modifiers: [String]) throws -> (CGKeyCode, CGEventFlags) {
        let shifted: [String: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
            "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
            "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
        ]
        guard let code = keys[shifted[key] ?? key.lowercased()] else { throw PluginSessionError.plugin("不支持的键名。") }
        var flags: CGEventFlags = shifted[key] == nil ? [] : .maskShift
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "meta", "command", "cmd": flags.insert(.maskCommand)
            default: throw PluginSessionError.plugin("不支持的修饰键。")
            }
        }
        return (code, flags)
    }

    @MainActor public static func requirePermission() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options)
        else { throw PluginSessionError.plugin("请在系统设置 → 隐私与安全性 → 辅助功能中允许 Leap，然后重试。") }
    }

    public static func tap(_ code: CGKeyCode, flags: CGEventFlags) throws {
        try Task.checkCancellation()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw PluginSessionError.plugin("无法创建键盘事件。")
        }
        down.flags = flags
        keyUp.flags = flags
        down.post(tap: .cghidEventTap)
        // 一旦按下必须配对释放，不能在两者之间响应取消导致按键卡住。
        keyUp.post(tap: .cghidEventTap)
    }

    public static func unicodeChunks(_ text: String) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { result.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    public static func type(_ units: [UInt16]) throws {
        try Task.checkCancellation()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw PluginSessionError.plugin("无法创建文本输入事件。")
        }
        down.flags = []
        keyUp.flags = []
        units.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
