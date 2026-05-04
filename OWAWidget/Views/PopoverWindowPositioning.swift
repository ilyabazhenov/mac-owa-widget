import CoreGraphics

enum PopoverWindowPositioning {
    static func leftAlignedOriginX(
        anchorX: CGFloat,
        windowWidth: CGFloat,
        visibleFrame: CGRect
    ) -> CGFloat {
        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - windowWidth)
        let preferredX = anchorX - windowWidth

        return min(max(preferredX, minX), maxX)
    }
}
