import CoreGraphics
import Testing

@testable import LeapCore

struct LauncherPanelGeometryTests {
    // 1080p 主屏去掉菜单栏后的可用区域。
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1083)
    private let fraction: CGFloat = 1 / 3

    /// 冷启动：窗口初始高度就是空态高度。
    private func coldStartTop(panelSize: CGSize) -> CGFloat {
        LauncherPanelGeometry.centeredOrigin(
            screen: visibleFrame, panelSize: panelSize, verticalFraction: fraction
        ).y + panelSize.height
    }

    @Test("中心落在可用高度的 1/3 处")
    func centersAtFraction() {
        let origin = LauncherPanelGeometry.centeredOrigin(
            screen: visibleFrame,
            panelSize: CGSize(width: 800, height: 214),
            verticalFraction: fraction
        )
        let centerY = origin.y + 214 / 2
        #expect(abs(centerY - (visibleFrame.maxY - visibleFrame.height / 3)) <= 1)
        #expect(abs(origin.x + 400 - visibleFrame.midX) <= 1)
    }

    @Test("唤起后按真实高度重算，顶边与冷启动一致")
    func settlesOnFreshHeight() {
        // 回归断言：上一次会话停在长列表（600 高）后收起，下一次唤起首帧仍沿用 600 的高度，
        // 布局报上 214 后必须重新居中；否则沿用 600 计算的顶边，启动器会贴着屏幕顶端。
        let empty = CGSize(width: 800, height: 214)
        let reused = CGSize(width: 800, height: 600)
        let reusedOrigin = LauncherPanelGeometry.centeredOrigin(
            screen: visibleFrame, panelSize: reused, verticalFraction: fraction
        )
        let reusedFrame = CGRect(origin: reusedOrigin, size: reused)

        let staleTop = LauncherPanelGeometry.keepingTopEdge(reusedFrame, size: empty).maxY
        let settledTop = LauncherPanelGeometry.centeredOrigin(
            screen: visibleFrame, panelSize: empty, verticalFraction: fraction
        ).y + empty.height

        #expect(abs(staleTop - settledTop) > 100)
        #expect(settledTop == coldStartTop(panelSize: empty))
    }

    @Test("高度变化时顶边不动、只向下伸展")
    func keepsTopEdge() {
        let frame = CGRect(x: 100, y: 300, width: 800, height: 214)
        let taller = LauncherPanelGeometry.keepingTopEdge(frame, size: CGSize(width: 800, height: 400))
        #expect(taller.maxY == frame.maxY)
        #expect(taller.height == 400)
        #expect(taller.origin.x == frame.origin.x)

        let shorter = LauncherPanelGeometry.keepingTopEdge(taller, size: CGSize(width: 800, height: 214))
        #expect(shorter == frame)
    }

    @Test("长页面按需向上让位，底部留出 12pt 边距")
    func clampsToScreen() {
        let frame = CGRect(x: 100, y: 300, width: 800, height: 214)
        let taller = LauncherPanelGeometry.keepingTopEdge(
            frame,
            size: CGSize(width: 800, height: 1000),
            clampingTo: visibleFrame.minY + 12
        )
        #expect(taller.origin.y == visibleFrame.minY + 12)
        #expect(taller.height == 1000)
    }
}
