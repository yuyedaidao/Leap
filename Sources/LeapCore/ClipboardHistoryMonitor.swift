import AppKit
import Foundation
import YQLogger

/// 采集只负责把剪切板内容交给历史存储；展示与粘贴仍由普通插件会话完成。
@MainActor
public final class ClipboardHistoryMonitor {
    private static let logger = YQLogger(label: "com.padding.leap/clipboard-history")
    private let pasteboard: NSPasteboard
    private let store: ClipboardHistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?

    public init(pasteboard: NSPasteboard = .general, store: ClipboardHistoryStore) {
        self.pasteboard = pasteboard
        self.store = store
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureIfNeeded() }
        }
        timer.tolerance = 0.1
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func suppressNextCapture() {
        suppressedChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    /// 定时器和测试共用同一入口；一轮只读取当前快照，不补录错过中间状态。
    func captureIfNeeded() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return
        }
        do { try capture() } catch {
            Self.logger.error("记录剪切板历史失败：\(error.localizedDescription)")
        }
    }

    private func capture() throws {
        let timestamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            try store.append(type: "files", files: urls.map(\.path), timestamp: timestamp)
        } else if let text = pasteboard.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.append(type: "text", text: text, timestamp: timestamp)
        } else if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                  let image = images.first, let png = Self.pngData(image) {
            try store.append(type: "image", image: png, timestamp: timestamp)
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        let representations = image.representations
        guard !representations.isEmpty, representations.allSatisfy({
            $0.pixelsWide > 0 && $0.pixelsHigh > 0 && $0.pixelsWide <= 64_000_000 / $0.pixelsHigh
        }), let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:]),
            !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        return data
    }
}
