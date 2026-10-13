import AppKit
import CoreGraphics
import LeapCore
import YQLogger

/// 在窗口展示前锁定前台屏幕，避免应用激活后读取到自己的旧窗口。
@MainActor
enum WindowDisplayResolver {
    private static let logger = YQLogger(label: "com.padding.leap/window-display")

    static func frontmostWindowDisplayID(
        fallbackDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            logger.debug("未找到前台应用，将使用鼠标所在屏幕。")
            return fallbackDisplayID
        }
        let frontmostPID = Int(frontmostApplication.processIdentifier)
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = windowList.compactMap(windowGeometry(from:))
        let displays = activeDisplayGeometries()
        guard !displays.isEmpty else {
            logger.debug("未获取到活动显示器，将使用鼠标所在屏幕。")
            return fallbackDisplayID
        }

        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: frontmostPID,
            windowsInFrontToBackOrder: windows,
            displays: displays,
            fallbackDisplayID: fallbackDisplayID
        )
        guard let displayID else {
            logger.debug("无法确定前台窗口的显示器，将使用鼠标所在屏幕。")
            return nil
        }
        logger.debug("已锁定窗口展示显示器 ID：\(displayID)，前台进程：\(frontmostPID)。")
        return displayID
    }

    private static func windowGeometry(from window: [String: Any]) -> WindowGeometry? {
        guard let ownerProcessID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let originX = (boundsDictionary["X"] as? NSNumber)?.doubleValue,
              let originY = (boundsDictionary["Y"] as? NSNumber)?.doubleValue,
              let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
              let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        // 请求已限定 optionOnScreenOnly；该可选字段缺失时不能把有效窗口误判为离屏。
        let isOnScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return WindowGeometry(
            ownerProcessID: ownerProcessID,
            layer: layer,
            isOnScreen: isOnScreen,
            alpha: alpha,
            bounds: CGRect(x: originX, y: originY, width: width, height: height)
        )
    }

    private static func activeDisplayGeometries() -> [DisplayGeometry] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }
        return displayIDs.prefix(Int(displayCount)).map {
            DisplayGeometry(id: $0, bounds: CGDisplayBounds($0))
        }
    }

    static func displayID(forMouseLocation location: NSPoint) -> CGDirectDisplayID? {
        NSScreen.leapScreen(containing: location)?.leapDisplayID
    }
}
