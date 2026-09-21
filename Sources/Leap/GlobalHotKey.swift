@preconcurrency import Carbon.HIToolbox
import Foundation
import YQLogger

@MainActor
final class GlobalHotKey {
    enum RegistrationError: LocalizedError {
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .registrationFailed(status):
                "无法注册全局快捷键（系统错误码：\(status)）。"
            }
        }
    }

    private static let logger = YQLogger(label: "com.padding.leap/global-hotkey")
    private static let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    private static let handler: EventHandlerUPP = { _, _, userData in
        guard let userData else {
            return noErr
        }

        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            hotKey.onPressed()
        }
        return noErr
    }

    private let onPressed: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyReference: EventHotKeyRef?

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
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
    }

    func registerOptionCommandL() throws {
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
            UInt32(kVK_ANSI_L),
            UInt32(optionKey | cmdKey),
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
        Self.logger.info("已注册 Option + Command + L 全局快捷键。")
    }
}
