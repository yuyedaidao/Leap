import CoreGraphics

public struct DisplayGeometry: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let bounds: CGRect

    public init(id: CGDirectDisplayID, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
    }
}

public struct WindowGeometry: Equatable, Sendable {
    public let ownerProcessID: Int
    public let layer: Int
    public let isOnScreen: Bool
    public let alpha: CGFloat
    public let bounds: CGRect

    public init(
        ownerProcessID: Int,
        layer: Int,
        isOnScreen: Bool,
        alpha: CGFloat,
        bounds: CGRect
    ) {
        self.ownerProcessID = ownerProcessID
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// 根据 Quartz 窗口列表顺序确定前台窗口所属的显示器。
public enum FrontmostWindowDisplayResolver {
    /// `windowsInFrontToBackOrder` 必须保留 Quartz 窗口列表由前至后的顺序。
    public static func displayID(
        forFrontmostProcessID frontmostProcessID: Int,
        windowsInFrontToBackOrder: [WindowGeometry],
        displays: [DisplayGeometry],
        fallbackDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        guard let window = windowsInFrontToBackOrder.first(where: {
            $0.ownerProcessID == frontmostProcessID
                && $0.layer == 0
                && $0.isOnScreen
                && $0.alpha > 0
                && isUsable($0.bounds)
        }) else {
            return fallbackDisplayID
        }

        return displayID(
            for: window.bounds,
            displays: displays,
            fallbackDisplayID: fallbackDisplayID
        ) ?? fallbackDisplayID
    }

    private static func displayID(
        for windowBounds: CGRect,
        displays: [DisplayGeometry],
        fallbackDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        let standardWindowBounds = windowBounds.standardized
        guard isUsable(standardWindowBounds) else {
            return nil
        }

        // Quartz 窗口边界和显示器边界同属全局显示坐标系，可直接比较而无需翻转坐标。
        let intersections = displays.compactMap { display -> (DisplayGeometry, CGFloat)? in
            let standardDisplayBounds = display.bounds.standardized
            guard isUsable(standardDisplayBounds) else {
                return nil
            }

            let intersection = standardWindowBounds.intersection(standardDisplayBounds)
            let area = intersection.width * intersection.height
            guard area > 0 else {
                return nil
            }
            return (display, area)
        }
        guard let largestArea = intersections.map({ $0.1 }).max() else {
            return nil
        }

        let largestDisplays = intersections.filter { $0.1 == largestArea }.map { $0.0 }
        guard largestDisplays.count > 1 else {
            return largestDisplays.first?.id
        }

        let center = CGPoint(x: standardWindowBounds.midX, y: standardWindowBounds.midY)
        if let centerDisplay = largestDisplays.first(where: {
            $0.bounds.standardized.contains(center)
        }) {
            return centerDisplay.id
        }

        return largestDisplays.first(where: { $0.id == fallbackDisplayID })?.id
    }

    private static func isUsable(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isInfinite && bounds.width > 0 && bounds.height > 0
    }
}
