import CoreGraphics

enum PanelAnchor {
    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    /// Bottom-left origin for a panel of `size`, horizontally centred on `anchor`,
    /// hanging `gap` below it, clamped inside `visibleFrame`.
    /// All rects are AppKit screen coordinates: origin bottom-left, y increases upward.
    static func origin(for size: CGSize, under anchor: CGRect, within visibleFrame: CGRect) -> CGPoint {
        var x = anchor.midX - size.width / 2
        let y = anchor.minY - gap - size.height

        let minX = visibleFrame.minX + screenMargin
        // Clamp against maxX first, minX second: if the panel is wider than
        // the screen, the left edge wins rather than the right.
        let maxX = visibleFrame.maxX - size.width - screenMargin
        x = max(minX, min(x, maxX))

        return CGPoint(x: x, y: max(y, visibleFrame.minY + screenMargin))
    }
}
