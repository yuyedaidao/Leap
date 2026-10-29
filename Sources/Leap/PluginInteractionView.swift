import AppKit
import ImageIO
import LeapCore
import SwiftUI

struct PluginInteractionView: View {
    let session: PluginInteractionSession

    var body: some View {
        VStack(spacing: 12) {
            if let error = session.errorMessage {
                Text(error).foregroundStyle(.red)
            } else if let list = session.list {
                PluginResultList(session: list)
            } else if let entry = session.command.manifest.webEntry {
                PluginWebView(
                    pageURL: session.command.pluginDirectory.appendingPathComponent(entry),
                    readAccessDirectory: session.command.pluginDirectory,
                    invoke: { await session.invoke(commandID: $0, query: $1) }, interaction: session,
                    committedInput: session.committedInput, submitID: session.submitID
                )
                .frame(height: webHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("plugin.embeddedWeb")
            }
        }
    }

    private var webHeight: CGFloat {
        let requested = CGFloat(session.command.manifest.webWindow?.height ?? 600) - 70
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 200
        return max(100, min(requested, available))
    }
}

struct PluginInteractionTag: View {
    let session: PluginInteractionSession
    let exit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 图标装饰与可访问的加载状态分开，避免隐藏图标时同时隐藏状态说明。
            ZStack {
                CommandIcon(iconURL: session.command.iconURL, runtime: session.command.manifest.runtime)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                if session.list?.isLoadingVisible == true {
                    PluginLoadingRing(isSelecting: session.list?.isSelecting == true)
                }
            }
            .frame(width: 28, height: 28)
            HStack(spacing: 6) {
                Text(session.command.pluginName)
                    .accessibilityIdentifier("plugin.activeName")
                if session.command.pluginName != session.configuration.title {
                    Text("/").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(session.configuration.title)
                        .accessibilityIdentifier("plugin.activeTitle")
                }
            }
            .font(.headline)
            .lineLimit(1)
            Button(action: exit) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出插件，返回搜索")
            .accessibilityIdentifier("plugin.backButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .help(session.command.pluginName == session.configuration.title
            ? session.command.pluginName : "\(session.command.pluginName) / \(session.configuration.title)")
    }
}

private struct PluginResultList: View {
    let session: PluginListSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = session.title {
                Text(title).font(.headline).lineLimit(1).help(title)
                    .accessibilityIdentifier("plugin.listTitle")
            }
            if !session.isLoading, session.items.isEmpty, session.message == nil {
                Text("没有结果，请输入或修改参数。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugin.emptyResults")
            }
            NativeResultList(items: session.items, selectedID: session.selectedID) { item, index in
                NativeResultRow(title: item.title, subtitle: item.description,
                                isSelected: item.id == session.selectedID,
                                shortcut: LauncherListShortcut.hint(at: index),
                                identifierPrefix: "plugin", itemID: item.id,
                                activate: { session.select(item.id) }) {
                    ImageThumbnail(path: item.imagePath)
                }
                .accessibilityIdentifier("plugin.result.\(item.id)")
                .disabled(session.isSelecting || session.isLoading)
            }
            .accessibilityIdentifier("plugin.results")

            if let message = session.message, !message.isEmpty {
                Text(message)
                    .foregroundStyle(session.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("plugin.listFeedback")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private enum ImageThumbnailCache {
    static let images = NSCache<NSString, NSImage>()
}

/// 列表项的图片缩略图：降采样加载避免大图占满内存，加载失败回退占位图标。
private struct ImageThumbnail: View {
    let path: String?

    var body: some View {
        if let path {
            if let image = Self.load(path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .frame(width: 96, height: 96)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @MainActor private static func load(_ path: String) -> NSImage? {
        let key = path as NSString
        if let cached = ImageThumbnailCache.images.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        ImageThumbnailCache.images.setObject(image, forKey: key)
        return image
    }
}

private struct PluginLoadingRing: View {
    let isSelecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        Circle().trim(from: 0, to: 0.75)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 32, height: 32)
            .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(isSelecting ? "正在执行" : "正在查询")
            .accessibilityIdentifier("plugin.loadingIndicator")
    }
}

/// AppKit 仅用于辨别输入法组合状态；SwiftUI TextField 的字符串变化无法可靠表达这个边界。
struct PluginParameterInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequestID: Int
    let commit: (String) -> Void
    let submit: () -> Void
    let move: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ParameterField {
        let field = ParameterField()
        field.isBordered = false
        field.drawsBackground = false
        // 与普通搜索框的 SwiftUI .title 使用同一系统文字样式。
        field.font = .preferredFont(forTextStyle: .title1)
        field.textColor = .labelColor
        field.focusRingType = .none
        // 插件参数需原样传递，系统补全浮层也会打断非激活面板的焦点。
        field.isAutomaticTextCompletionEnabled = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("plugin.parameterInput")
        return field
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParameterField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        // 原生文本框须接受剩余宽度，不能用占位文字的固有宽度把设置按钮挤出输入栏。
        return CGSize(width: max(0, width), height: proposal.height ?? nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: ParameterField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        if context.coordinator.focusID != focusRequestID {
            context.coordinator.focusID = focusRequestID
            field.window?.makeFirstResponder(field)
        }
    }

    final class ParameterField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 等 SwiftUI 移除旧搜索框后再交接 field editor，避免非激活面板丢失键盘焦点。
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PluginParameterInput
        var focusID: Int?
        init(_ parent: PluginParameterInput) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.commit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.commit(textView.string)
                parent.submit()
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            default: return false
            }
            return true
        }
    }
}
