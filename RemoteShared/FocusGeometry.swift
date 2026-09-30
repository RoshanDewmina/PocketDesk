import Foundation
import CoreGraphics

/// Where the focused editable control sits on the captured display: display-local points with a
/// top-left origin, the space `geometry` announced and `moveTo` uses. Geometry only; the Mac never
/// sends a field's contents, label or window title. Rides on a text-focus reply after the phone
/// asked for it on a probe (`SessionFeature.focusGeometry`).
struct FocusGeometry: Codable, Equatable {
    var displayWidth: Double
    var displayHeight: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// The click point, or the insertion point when the app exposes it, inside the rect.
    var anchorX: Double? = nil
    var anchorY: Double? = nil

    static let quantum = 64.0

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var displaySize: CGSize { CGSize(width: displayWidth, height: displayHeight) }
    var anchor: CGPoint? {
        guard let anchorX, let anchorY else { return nil }
        return CGPoint(x: anchorX, y: anchorY)
    }

    func validate() throws {
        let limit = ViewportRegion.maximumPoints
        let values = [displayWidth, displayHeight, x, y, width, height] + [anchorX, anchorY].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite }),
              displayWidth >= 1, displayHeight >= 1, displayWidth <= limit, displayHeight <= limit,
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= displayWidth + 0.5, y + height <= displayHeight + 0.5,
              (anchorX == nil) == (anchorY == nil)
        else { throw RemoteError.invalidMessage }
        if let anchorX, let anchorY {
            guard anchorX >= x - 0.5, anchorX <= x + width + 0.5,
                  anchorY >= y - 0.5, anchorY <= y + height + 0.5 else { throw RemoteError.invalidMessage }
        }
    }

    /// Converts an Accessibility frame (global CoreGraphics points, top-left origin of the main display)
    /// into the captured display. `displayFrame` is that display in the same global space, so a secondary
    /// display left of or above the main one has a negative origin. `geometrySize` is the size the phone was
    /// told; it equals the frame's point size today, and scales the result if it ever carries pixels. The
    /// rect is clipped to the display; nothing survives when the field is entirely elsewhere.
    static func make(field: CGRect, anchor: CGPoint?, displayFrame: CGRect, geometrySize: CGSize) -> FocusGeometry? {
        guard isFinite(field), isFinite(displayFrame), geometrySize.width.isFinite, geometrySize.height.isFinite,
              displayFrame.width > 0, displayFrame.height > 0, geometrySize.width >= 1, geometrySize.height >= 1,
              geometrySize.width <= ViewportRegion.maximumPoints, geometrySize.height <= ViewportRegion.maximumPoints
        else { return nil }
        let clipped = field.standardized.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let scaleX = geometrySize.width / displayFrame.width
        let scaleY = geometrySize.height / displayFrame.height
        func localX(_ value: CGFloat) -> Double { min(max(q((value - displayFrame.minX) * scaleX), 0), geometrySize.width) }
        func localY(_ value: CGFloat) -> Double { min(max(q((value - displayFrame.minY) * scaleY), 0), geometrySize.height) }
        let minX = localX(clipped.minX), maxX = localX(clipped.maxX)
        let minY = localY(clipped.minY), maxY = localY(clipped.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        var result = FocusGeometry(displayWidth: geometrySize.width, displayHeight: geometrySize.height,
                                   x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let anchor, anchor.x.isFinite, anchor.y.isFinite {
            result.anchorX = min(max(localX(anchor.x), minX), maxX)
            result.anchorY = min(max(localY(anchor.y), minY), maxY)
        }
        return (try? result.validate()) == nil ? nil : result
    }

    private static func q(_ value: CGFloat) -> Double { (Double(value) * quantum).rounded() / quantum }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

/// A focus rect the phone accepted for its current display, in viewport source points.
struct FocusTarget: Equatable {
    let rect: CGRect
    let anchor: CGPoint?
    let epoch: UInt64
    /// A re-query after typing rather than a click; it may only move a view that already has a target.
    let refresh: Bool
    let revision: UInt64

    /// Nil when the geometry was measured against another display size than the phone's source.
    init?(_ geometry: FocusGeometry, sourceSize: CGSize, epoch: UInt64, refresh: Bool, revision: UInt64) {
        guard (try? geometry.validate()) != nil,
              abs(geometry.displayWidth - Double(sourceSize.width)) <= 0.5,
              abs(geometry.displayHeight - Double(sourceSize.height)) <= 0.5 else { return nil }
        rect = geometry.rect
        anchor = geometry.anchor
        self.epoch = epoch
        self.refresh = refresh
        self.revision = revision
    }
}

enum FocusReveal {
    /// The part of a field to keep visible in a view that shows `span` source points. A field that fits is
    /// shown whole; a larger one is shown around its anchor, or from its leading edge without one.
    static func region(field: CGRect, anchor: CGPoint?, span: CGSize) -> CGRect {
        func axis(_ start: CGFloat, _ length: CGFloat, _ anchor: CGFloat?, _ span: CGFloat) -> (CGFloat, CGFloat) {
            guard span > 0, length > span else { return (start, length) }
            let centre = anchor ?? start + span / 2
            return (min(max(centre - span / 2, start), start + length - span), span)
        }
        let (x, width) = axis(field.minX, field.width, anchor?.x, span.width)
        let (y, height) = axis(field.minY, field.height, anchor?.y, span.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension RemoteAction {
    /// The phone asks for geometry on a probe it sends; the Mac answers with it only on an editable reply.
    func validateFocusGeometry() throws {
        if let textFocusRect {
            guard action == "heartbeat", textFocusProbe != nil, textFocusEditable == true else {
                throw RemoteError.invalidMessage
            }
            try textFocusRect.validate()
        }
        if textFocusGeometry != nil {
            guard textFocusGeometry == true, textFocusProbe != nil,
                  ["click", "double", "text", "key"].contains(action) else { throw RemoteError.invalidMessage }
        }
        if textFocusProbe != nil, ["text", "key"].contains(action), textFocusGeometry != true {
            throw RemoteError.invalidMessage
        }
    }
}
