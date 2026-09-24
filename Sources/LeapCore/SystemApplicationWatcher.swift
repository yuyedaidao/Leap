import CoreServices
import Foundation

/// 只监听标准应用目录；事件合并后由调用方重扫对应目录，避免维护脆弱的增量状态。
public final class SystemApplicationWatcher: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (_ roots: Set<String>, _ requiresFullRescan: Bool) -> Void

    private let roots: [String]
    private let queue = DispatchQueue(label: "com.padding.leap.application-watcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let changeHandler: ChangeHandler
    private var stream: FSEventStreamRef?
    private var pendingRoots = Set<String>()
    private var requiresFullRescan = false
    private var debounceWorkItem: DispatchWorkItem?

    public init(roots: [URL], changeHandler: @escaping ChangeHandler) {
        self.roots = roots.map { $0.standardizedFileURL.path }
        self.changeHandler = changeHandler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.stream == nil, !self.roots.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.receiveEvents,
                &context,
                self.roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                // 回调将 eventPaths 按 CFArray<CFString> 传入，才能安全桥接为 Swift 字符串数组。
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                )
            )
            guard let stream else { return }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopStream()
        } else {
            queue.sync { stopStream() }
        }
    }

    private static let receiveEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<SystemApplicationWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.enqueue(paths: paths, flags: eventFlags, count: eventCount)
    }

    private func enqueue(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        let fullRescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        for index in 0 ..< min(count, paths.count) {
            if flags[index] & fullRescanFlags != 0 { requiresFullRescan = true }
            if let root = roots.first(where: { paths[index] == $0 || paths[index].hasPrefix($0 + "/") }) {
                pendingRoots.insert(root)
            }
        }
        guard !pendingRoots.isEmpty || requiresFullRescan else { return }
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.flushChanges() }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: workItem)
    }

    private func flushChanges() {
        let changedRoots = pendingRoots
        let fullRescan = requiresFullRescan
        pendingRoots.removeAll()
        requiresFullRescan = false
        debounceWorkItem = nil
        changeHandler(changedRoots, fullRescan)
    }

    private func stopStream() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
