import AppKit
import CoreGraphics

extension NSScreen {
    var leapDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func leapScreen(containing location: NSPoint) -> NSScreen? {
        screens.first { $0.frame.contains(location) }
    }
}
