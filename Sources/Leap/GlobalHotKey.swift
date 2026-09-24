@preconcurrency import Carbon.HIToolbox
import AppKit
import CoreGraphics
import Foundation
import YQLogger

struct HotKeyShortcut: Codable, Equatable, Sendable {
    static let defaultValue = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(optionKey | cmdKey),
        keyLabel: "L"
    )

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var isValid: Bool {
        !keyLabel.isEmpty && modifiers & Self.requiredModifierMask != 0
    }

    var displayName: String {
        var display = ""
        if modifiers & UInt32(cmdKey) != 0 { display += "⌘" }
        if modifiers & UInt32(optionKey) != 0 { display += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { display += "⌃" }
        if modifiers & UInt32(shiftKey) != 0 { display += "⇧" }
        return display + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let label = event.charactersIgnoringModifiers?.uppercased() ?? "键码 \(event.keyCode)"
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers, keyLabel: label)
        guard isValid else { return nil }
    }

    private static let requiredModifierMask = UInt32(cmdKey | optionKey | controlKey)
}

struct HotKeyShortcutStore {
    private static let key = "globalHotKeyShortcut"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HotKeyShortcut {
        guard let data = defaults.data(forKey: Self.key),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid else {
            return .defaultValue
        }
        return shortcut
    }

    func save(_ shortcut: HotKeyShortcut) {
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

@MainActor
final class GlobalHotKey {
    enum RegistrationError: LocalizedError {
        case registrationFailed(OSStatus)
        case invalidShortcut

        var errorDescription: String? {
            switch self {
            case let .registrationFailed(status):
                "无法注册全局快捷键（系统错误码：\(status)）。"
            case .invalidShortcut:
                "全局快捷键必须包含 Command、Option 或 Control。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/global-hotkey")
    private static let eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    private static let handler: EventHandlerUPP = { _, _, userData in
        guard let userData else {
            return noErr
        }

        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        // Carbon 回调会异步切换到主线程；在激活 Leap 前锁定前台窗口所在显示器。
        let targetDisplayID = GlobalHotKey.frontmostWindowDisplayID()
        let fallbackLocation = NSEvent.mouseLocation
        Task { @MainActor in
            hotKey.onPressed(targetDisplayID, fallbackLocation)
        }
        return noErr
    }

    private let onPressed: (CGDirectDisplayID?, NSPoint) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyReference: EventHotKeyRef?
    private(set) var shortcut: HotKeyShortcut?

    init(onPressed: @escaping (CGDirectDisplayID?, NSPoint) -> Void) {
        self.onPressed = onPressed
    }

    private static func frontmostWindowDisplayID() -> CGDirectDisplayID? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            logger.debug("未找到前台应用，将使用鼠标所在屏幕。")
            return nil
        }
        let frontmostPID = Int(frontmostApplication.processIdentifier)
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard let window = windowList.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == frontmostPID
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }),
            let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
            let originX = (boundsDictionary["X"] as? NSNumber)?.doubleValue,
            let originY = (boundsDictionary["Y"] as? NSNumber)?.doubleValue,
            let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
            let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue,
            width > 0,
            height > 0
        else {
            logger.debug("未找到前台窗口，将使用鼠标所在屏幕。")
            return nil
        }
        let bounds = CGRect(x: originX, y: originY, width: width, height: height)

        var displayID: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        let result = CGGetDisplaysWithPoint(
            CGPoint(x: bounds.midX, y: bounds.midY),
            1,
            &displayID,
            &displayCount
        )
        guard result == .success, displayCount == 1 else {
            logger.debug("无法确定前台窗口的显示器，将使用鼠标所在屏幕。")
            return nil
        }
        return displayID
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        shortcut = nil
    }

    func register(_ shortcut: HotKeyShortcut) throws {
        guard shortcut.isValid else {
            throw RegistrationError.invalidShortcut
        }
        guard hotKeyReference == nil else {
            return
        }

        var eventHandler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handler,
            1,
            [Self.eventType],
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        self.eventHandler = eventHandler

        var hotKeyReference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C454150), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard status == noErr, let hotKeyReference else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            self.eventHandler = nil
            throw RegistrationError.registrationFailed(status)
        }

        self.hotKeyReference = hotKeyReference
        self.shortcut = shortcut
        Self.logger.info("已注册 \(shortcut.displayName) 全局快捷键。")
    }
}
