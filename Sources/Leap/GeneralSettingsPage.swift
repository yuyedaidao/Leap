import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    let coordinator: SettingsCoordinator
    let appearance: Binding<AppearancePreference>

    var body: some View {
        Form {
            LaunchBehaviorSection(coordinator: coordinator, appearance: appearance)
            GlobalShortcutSection(coordinator: coordinator)
        }
        .formStyle(.grouped)
        .padding(24)
        .onAppear(perform: coordinator.refreshLoginItemState)
    }
}

private struct LaunchBehaviorSection: View {
    let coordinator: SettingsCoordinator
    let appearance: Binding<AppearancePreference>

    var body: some View {
        Section("启动器") {
            Toggle(
                "登录时启动 Leap",
                isOn: Binding(
                    get: { coordinator.loginItemState.isEnabled },
                    set: { isEnabled in
                        coordinator.setLaunchAtLogin(isEnabled)
                    }
                )
            )
            .accessibilityIdentifier("settings.launchAtLoginToggle")

            if let detail = coordinator.loginItemState.detail {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail)
                        .foregroundStyle(.secondary)
                    if coordinator.loginItemState == .requiresApproval {
                        Button("打开登录项设置", action: coordinator.openSystemLoginItems)
                    }
                }
            }
            if let error = coordinator.loginItemError {
                SettingsErrorMessage(error)
            }

            Picker("外观", selection: appearance) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearancePicker")
        }
    }
}

private struct GlobalShortcutSection: View {
    let coordinator: SettingsCoordinator

    var body: some View {
        Section("全局快捷键") {
            LabeledContent("唤起 Leap") {
                ShortcutRecorder(shortcut: coordinator.shortcut, onRecord: coordinator.updateShortcut)
                    .frame(width: 160)
            }
            Text("快捷键必须包含 Command、Option 或 Control；如果系统拒绝注册，将继续使用原来的组合。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("恢复默认（⌥⌘L）", action: coordinator.restoreDefaultShortcut)
                .disabled(coordinator.shortcut == .defaultValue)
            if let error = coordinator.shortcutError {
                SettingsErrorMessage(error)
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    let onRecord: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton(title: shortcut.displayName, target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("settings.shortcutRecorder")
        button.onRecord = onRecord
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.title = shortcut.displayName
        button.onRecord = onRecord
    }
}

private final class HotKeyRecorderButton: NSButton {
    var onRecord: ((HotKeyShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // NSButton 点击后默认不会保留键盘焦点，录制器必须主动接收随后的组合键事件。
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        title = "按下新快捷键"
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let shortcut = HotKeyShortcut(event: event) else {
            NSSound.beep()
            return
        }
        onRecord?(shortcut)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }
}
