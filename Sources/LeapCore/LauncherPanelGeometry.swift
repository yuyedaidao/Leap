import CoreGraphics

/// 启动器面板落点计算：纯几何，便于单独验证。
public enum LauncherPanelGeometry {
    /// 让面板中心落在屏幕可用高度的 `verticalFraction` 处（0 为屏幕顶部，1 为底部）。
    public static func centeredOrigin(
        screen: CGRect,
        panelSize: CGSize,
        verticalFraction: CGFloat
    ) -> CGPoint {
        let centerY = screen.maxY - screen.height * verticalFraction
        return CGPoint(
            x: (screen.midX - panelSize.width / 2).rounded(),
            y: (centerY - panelSize.height / 2).rounded()
        )
    }

    /// 保持顶边不动、只改高度，并按需把窗口底部夹回屏幕内。
    public static func keepingTopEdge(
        _ frame: CGRect,
        size: CGSize,
        clampingTo minimumOriginY: CGFloat? = nil
    ) -> CGRect {
        var target = frame
        target.size = size
        // AppKit 坐标原点位于左下角，因此固定 maxY 即可让窗口只向下伸展。
        target.origin.y = frame.maxY - size.height
        if let minimumOriginY {
            target.origin.y = max(minimumOriginY, target.origin.y)
        }
        return target
    }
}
