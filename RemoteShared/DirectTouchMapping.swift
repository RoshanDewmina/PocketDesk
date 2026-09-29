import CoreGraphics

/// Where an absolute touch or hardware pointer lands on the Mac. A canvas point is mapped through
/// the current viewport into display-local logical points (the `geometry` size the host sent).
/// Points outside the picture, such as Fit's letterbox bands, have no target and never click.
enum DirectTouchMapping {
    /// Positions travel in 1/64 pt steps, the same quantum as pointer telemetry.
    static let quantum: CGFloat = 64

    static func sourcePoint(for canvasPoint: CGPoint, in viewport: ViewportTransform) -> CGPoint? {
        guard let point = viewport.sourcePoint(fromView: canvasPoint) else { return nil }
        let size = viewport.sourceSize
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: quantized(point.x, limit: size.width), y: quantized(point.y, limit: size.height))
    }

    private static func quantized(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        min(max(0, (value * quantum).rounded() / quantum), limit)
    }
}
