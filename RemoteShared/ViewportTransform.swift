import Foundation
import CoreGraphics

public enum ViewportMode: Equatable {
    case fill
    case fit
}

/// Maps a captured source image into a client canvas without depending on a UI framework.
///
/// `zoom` is relative to the selected Fill or Fit baseline. `offset` is measured in
/// canvas points from that baseline; it is clamped so cropped dimensions keep covering
/// the canvas and letterboxed dimensions stay centered.
public struct ViewportTransform {
    public private(set) var sourceSize: CGSize
    public private(set) var canvasSize: CGSize
    public private(set) var mode: ViewportMode
    public private(set) var zoom: CGFloat
    public private(set) var offset: CGPoint

    public init(sourceSize: CGSize, canvasSize: CGSize, mode: ViewportMode = .fill,
                zoom: CGFloat = 1, offset: CGPoint = CGPoint()) {
        self.sourceSize = Self.validSize(sourceSize)
        self.canvasSize = Self.validSize(canvasSize)
        self.mode = mode
        self.zoom = Self.clampedZoom(zoom)
        self.offset = Self.finitePoint(offset)
        self.offset = clampedOffset(self.offset)
    }

    /// The scale that fits the full source inside the canvas while preserving aspect ratio.
    public var fitScale: CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return 0
        }

        let value = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        return value.isFinite && value > 0 ? value : 0
    }

    /// The scale that covers the whole canvas without stretching the source.
    public var fillScale: CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 0 }
        let value = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        return value.isFinite && value > 0 ? value : 0
    }

    /// The current source-to-canvas scale after applying user zoom.
    public var scale: CGFloat {
        let value = (mode == .fill ? fillScale : fitScale) * zoom
        return value.isFinite && value > 0 ? value : 0
    }

    /// The source's rendered rectangle in canvas coordinates.
    public var contentRect: CGRect {
        guard scale > 0 else { return CGRect() }

        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        guard size.width.isFinite, size.height.isFinite else { return CGRect() }

        let originX = (canvasSize.width - size.width) / 2 + offset.x
        let originY = (canvasSize.height - size.height) / 2 + offset.y
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    /// Converts a canvas point to a source point. Points in letterbox bars have no source mapping.
    public func sourcePoint(fromView point: CGPoint) -> CGPoint? {
        guard Self.isFinite(point), scale > 0,
              point.x >= 0, point.x <= canvasSize.width,
              point.y >= 0, point.y <= canvasSize.height else { return nil }

        let rect = contentRect
        let minimumX = rect.origin.x
        let maximumX = rect.origin.x + rect.size.width
        let minimumY = rect.origin.y
        let maximumY = rect.origin.y + rect.size.height
        guard point.x >= minimumX, point.x <= maximumX,
              point.y >= minimumY, point.y <= maximumY else {
            return nil
        }

        let mapped = CGPoint(
            x: (point.x - minimumX) / scale,
            y: (point.y - minimumY) / scale
        )
        guard Self.isFinite(mapped) else { return nil }

        return CGPoint(
            x: min(max(mapped.x, 0), sourceSize.width),
            y: min(max(mapped.y, 0), sourceSize.height)
        )
    }

    /// Converts a source point to its canvas position. Invalid inputs produce `.zero`.
    public func viewPoint(fromSource point: CGPoint) -> CGPoint {
        guard Self.isFinite(point), scale > 0 else { return CGPoint() }

        let rect = contentRect
        let mapped = CGPoint(x: rect.origin.x + point.x * scale, y: rect.origin.y + point.y * scale)
        return Self.isFinite(mapped) ? mapped : CGPoint()
    }

    /// Changes zoom while keeping the source point under `anchor` in place when possible.
    public mutating func setZoom(_ zoom: CGFloat, anchoredAt anchor: CGPoint) {
        let sourceAnchor = sourcePoint(fromView: anchor)
        self.zoom = Self.clampedZoom(zoom)

        guard let sourceAnchor, Self.isFinite(anchor), scale > 0 else {
            offset = clampedOffset(offset)
            return
        }

        let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let centeredOrigin = CGPoint(
            x: (canvasSize.width - scaledSize.width) / 2,
            y: (canvasSize.height - scaledSize.height) / 2
        )
        offset = clampedOffset(CGPoint(
            x: anchor.x - centeredOrigin.x - sourceAnchor.x * scale,
            y: anchor.y - centeredOrigin.y - sourceAnchor.y * scale
        ))
    }

    /// Moves the rendered source by a canvas-space translation.
    public mutating func pan(by translation: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        offset = clampedOffset(CGPoint(
            x: offset.x + translation.width,
            y: offset.y + translation.height
        ))
    }

    /// Pans only as far as needed to bring a source point into the usable canvas.
    /// The visible rectangle is in full-canvas coordinates and may exclude safe areas
    /// or a dock. Returns true only when the offset actually changes.
    @discardableResult
    public mutating func reveal(sourcePoint: CGPoint, in visibleRect: CGRect,
                                margin: CGFloat = 32) -> Bool {
        guard Self.isFinite(sourcePoint), scale > 0,
              sourcePoint.x >= 0, sourcePoint.x <= sourceSize.width,
              sourcePoint.y >= 0, sourcePoint.y <= sourceSize.height,
              margin.isFinite, margin >= 0,
              visibleRect.origin.x.isFinite, visibleRect.origin.y.isFinite,
              visibleRect.width.isFinite, visibleRect.height.isFinite,
              visibleRect.width > 0, visibleRect.height > 0,
              contentRect.width > 0, contentRect.height > 0 else { return false }

        let canvas = CGRect(origin: .zero, size: canvasSize)
        let usable = visibleRect.intersection(canvas)
        guard !usable.isNull, usable.width > 0, usable.height > 0 else { return false }

        // Leave a useful central region even when the safe area is very small.
        let insetX = min(margin, usable.width / 4)
        let insetY = min(margin, usable.height / 4)
        let position = viewPoint(fromSource: sourcePoint)
        let target = CGPoint(
            x: min(max(position.x, usable.minX + insetX), usable.maxX - insetX),
            y: min(max(position.y, usable.minY + insetY), usable.maxY - insetY)
        )
        // Subpixel rounding at the margin must not trigger endless follow updates.
        let deltaX = abs(target.x - position.x) > 0.000_001 ? target.x - position.x : 0
        let deltaY = abs(target.y - position.y) > 0.000_001 ? target.y - position.y : 0
        guard deltaX != 0 || deltaY != 0 else { return false }
        let previous = offset
        offset = clampedOffset(CGPoint(x: offset.x + deltaX, y: offset.y + deltaY))
        return abs(offset.x - previous.x) > 0.000_001 ||
               abs(offset.y - previous.y) > 0.000_001
    }

    /// Retains the normalized center focal point after manual zoom or pan.
    /// A baseline Fill or Fit view remains centered through geometry changes.
    public mutating func resize(sourceSize: CGSize, canvasSize: CGSize) {
        let isAtBaseline = zoom == 1 && offset == CGPoint()
        let oldCenter = CGPoint(x: self.canvasSize.width / 2, y: self.canvasSize.height / 2)
        let oldFocalPoint = sourcePoint(fromView: oldCenter)
        let normalizedFocalPoint: CGPoint? = {
            guard let oldFocalPoint, self.sourceSize.width > 0, self.sourceSize.height > 0 else { return nil }
            return CGPoint(x: oldFocalPoint.x / self.sourceSize.width, y: oldFocalPoint.y / self.sourceSize.height)
        }()

        self.sourceSize = Self.validSize(sourceSize)
        self.canvasSize = Self.validSize(canvasSize)

        guard !isAtBaseline, let normalizedFocalPoint, scale > 0 else {
            offset = clampedOffset(CGPoint())
            return
        }

        let scaledSize = CGSize(width: self.sourceSize.width * scale, height: self.sourceSize.height * scale)
        let centeredOrigin = CGPoint(
            x: (self.canvasSize.width - scaledSize.width) / 2,
            y: (self.canvasSize.height - scaledSize.height) / 2
        )
        let center = CGPoint(x: self.canvasSize.width / 2, y: self.canvasSize.height / 2)
        offset = clampedOffset(CGPoint(
            x: center.x - centeredOrigin.x - normalizedFocalPoint.x * self.sourceSize.width * scale,
            y: center.y - centeredOrigin.y - normalizedFocalPoint.y * self.sourceSize.height * scale
        ))
    }

    /// Covers the canvas while preserving the source aspect ratio.
    public mutating func fill() { setMode(.fill) }

    /// Shows the whole source with letterboxing where needed.
    public mutating func fit() { setMode(.fit) }

    private mutating func setMode(_ mode: ViewportMode) {
        self.mode = mode
        zoom = 1
        offset = CGPoint()
    }

    private func clampedOffset(_ proposed: CGPoint) -> CGPoint {
        guard scale > 0 else { return CGPoint() }

        let contentSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        guard contentSize.width.isFinite, contentSize.height.isFinite else { return CGPoint() }

        return CGPoint(
            x: Self.clampedOffset(proposed.x, content: contentSize.width, canvas: canvasSize.width),
            y: Self.clampedOffset(proposed.y, content: contentSize.height, canvas: canvasSize.height)
        )
    }

    private static func clampedOffset(_ value: CGFloat, content: CGFloat, canvas: CGFloat) -> CGFloat {
        guard value.isFinite, content.isFinite, canvas.isFinite, content > canvas else { return 0 }
        let limit = (content - canvas) / 2
        return min(max(value, -limit), limit)
    }

    private static func validSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return CGSize() }
        return size
    }

    private static func clampedZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, 1), 3)
    }

    private static func finitePoint(_ point: CGPoint) -> CGPoint {
        isFinite(point) ? point : CGPoint()
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
