import CoreGraphics
import Foundation

/// D34 amendment: follow also applies while a click is held (drag auto-pan). While the pointer
/// sits in the edge band of the visible region, the picture scrolls toward that edge at a speed
/// that ramps with depth. The pointer keeps its place on screen, so the Mac point under it moves
/// with the picture and the drop lands exactly where the user sees it.
enum DragAutoPan {
    /// Width of the edge band, in canvas points.
    static let band: CGFloat = 72
    /// Canvas points per second at full depth.
    static let maxSpeed: CGFloat = 900
    /// Ordinary follow margin while a click is held: it only catches a pointer pushed past the
    /// band, leaving the band itself to auto-pan.
    static let revealMargin: CGFloat = 16

    /// The canvas-space translation for one tick. Zero outside the band.
    static func translation(pointer: CGPoint, usable: CGRect, dt: TimeInterval,
                            band: CGFloat = band, maxSpeed: CGFloat = maxSpeed) -> CGSize {
        guard dt.isFinite, dt > 0, pointer.x.isFinite, pointer.y.isFinite,
              usable.width > 0, usable.height > 0, band > 0, maxSpeed > 0 else { return .zero }
        let step = maxSpeed * CGFloat(min(dt, 0.1))
        func axis(_ position: CGFloat, _ low: CGFloat, _ high: CGFloat, _ width: CGFloat) -> CGFloat {
            let edge = min(band, width / 4)
            // Quadratic ramp: gentle at the band's inner boundary, full speed at the edge.
            if position < low + edge {
                let depth = min(1, (low + edge - position) / edge)
                return step * depth * depth
            }
            if position > high - edge {
                let depth = min(1, (position - (high - edge)) / edge)
                return -step * depth * depth
            }
            return 0
        }
        return CGSize(width: axis(pointer.x, usable.minX, usable.maxX, usable.width),
                      height: axis(pointer.y, usable.minY, usable.maxY, usable.height))
    }

    /// Pans the viewport one tick and returns the source point now under the unchanged screen
    /// position of the pointer, or nil when nothing moved (outside the band or at a source edge).
    /// Scale is preserved; the offset stays clamped to the source edges.
    static func step(_ viewport: inout ViewportTransform, pointerSource: CGPoint, usable: CGRect,
                     dt: TimeInterval) -> CGPoint? {
        guard pointerSource.x.isFinite, pointerSource.y.isFinite, viewport.scale > 0 else { return nil }
        let screen = viewport.viewPoint(fromSource: pointerSource)
        let delta = translation(pointer: screen, usable: usable, dt: dt)
        guard delta != .zero else { return nil }
        let before = viewport.offset
        viewport.pan(by: delta)
        guard abs(viewport.offset.x - before.x) > 0.000_001 || abs(viewport.offset.y - before.y) > 0.000_001,
              let source = viewport.sourcePoint(fromView: screen) else { return nil }
        return source
    }
}
