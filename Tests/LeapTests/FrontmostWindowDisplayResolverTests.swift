import CoreGraphics
import Testing
@testable import LeapCore

struct FrontmostWindowDisplayResolverTests {
    @Test("副屏前台窗口优先于主屏鼠标")
    func selectsFrontmostWindowDisplayOverMouseDisplay() {
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 2_000, y: 100, width: 800, height: 600))
            ],
            displays: horizontalDisplays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 2)
    }

    @Test("跨屏窗口按最大重叠面积选择显示器")
    func selectsDisplayWithLargestIntersection() {
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 1_800, y: 100, width: 700, height: 600))
            ],
            displays: horizontalDisplays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 2)
    }

    @Test("窗口中心落在显示器间隙时仍使用最大重叠面积")
    func selectsLargestIntersectionWhenCenterIsInGap() {
        let displays = [
            display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
            display(id: 2, bounds: CGRect(x: 1_920, y: 500, width: 1_920, height: 1_080))
        ]
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 1_700, y: 100, width: 500, height: 600))
            ],
            displays: displays,
            fallbackDisplayID: 2
        )

        #expect(displayID == 1)
    }

    @Test("等面积跨屏优先使用包含窗口中心的显示器")
    func usesCenterDisplayForEqualIntersections() {
        let displays = [
            display(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            display(id: 2, bounds: CGRect(x: 100, y: 0, width: 100, height: 100))
        ]
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 50, y: 0, width: 100, height: 100))
            ],
            displays: displays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 2)
    }

    @Test("等面积且中心不属于候选显示器时使用鼠标所在候选显示器")
    func usesFallbackDisplayForUnresolvedEqualIntersections() {
        let displays = [
            display(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            display(id: 2, bounds: CGRect(x: 200, y: 0, width: 100, height: 100))
        ]
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 0, y: 0, width: 300, height: 100))
            ],
            displays: displays,
            fallbackDisplayID: 2
        )

        #expect(displayID == 2)
    }

    @Test("同一应用多个窗口时仅使用最上层可见普通窗口")
    func selectsFirstEligibleWindowInFrontToBackOrder() {
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 2_000, y: 0, width: 500, height: 500)),
                window(ownerProcessID: 42, bounds: CGRect(x: 100, y: 0, width: 500, height: 500))
            ],
            displays: horizontalDisplays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 2)
    }

    @Test("没有有效前台窗口时回退到鼠标显示器")
    func fallsBackWhenNoEligibleWindowExists() {
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                WindowGeometry(
                    ownerProcessID: 42,
                    layer: 3,
                    isOnScreen: true,
                    alpha: 1,
                    bounds: CGRect(x: 2_000, y: 0, width: 500, height: 500)
                )
            ],
            displays: horizontalDisplays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 1)
    }

    @Test("前台窗口不与任何活动显示器相交时回退到鼠标显示器")
    func fallsBackWhenWindowDoesNotIntersectAnActiveDisplay() {
        let displayID = FrontmostWindowDisplayResolver.displayID(
            forFrontmostProcessID: 42,
            windowsInFrontToBackOrder: [
                window(ownerProcessID: 42, bounds: CGRect(x: 5_000, y: 0, width: 500, height: 500))
            ],
            displays: horizontalDisplays,
            fallbackDisplayID: 1
        )

        #expect(displayID == 1)
    }

    private var horizontalDisplays: [DisplayGeometry] {
        [
            display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
            display(id: 2, bounds: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080))
        ]
    }

    private func display(id: CGDirectDisplayID, bounds: CGRect) -> DisplayGeometry {
        DisplayGeometry(id: id, bounds: bounds)
    }

    private func window(ownerProcessID: Int, bounds: CGRect) -> WindowGeometry {
        WindowGeometry(
            ownerProcessID: ownerProcessID,
            layer: 0,
            isOnScreen: true,
            alpha: 1,
            bounds: bounds
        )
    }
}
