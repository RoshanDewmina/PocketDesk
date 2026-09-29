import CoreGraphics

/// Geometry for the mini map: a small overview of the whole Mac display with the part the
/// viewport shows. Dragging the viewport rectangle pans the view; tapping jumps there.
/// Pure, so the mapping is tested without UIKit.
struct MiniMapLayout: Equatable {
    /// The overview's drawn size; it keeps the display's aspect ratio.
    let mapSize: CGSize
    let sourceSize: CGSize

    /// The overview fitted inside `bounds`, or nil for an empty display.
    init?(sourceSize: CGSize, fitting bounds: CGSize) {
        guard sourceSize.width > 0, sourceSize.height > 0, sourceSize.width.isFinite, sourceSize.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        guard scale.isFinite, scale > 0 else { return nil }
        self.sourceSize = sourceSize
        mapSize = CGSize(width: (sourceSize.width * scale).rounded(), height: (sourceSize.height * scale).rounded())
    }

    /// Map points per source point on each axis (they differ only by rounding).
    var scaleX: CGFloat { mapSize.width / sourceSize.width }
    var scaleY: CGFloat { mapSize.height / sourceSize.height }

    /// The viewport rectangle on the map, never smaller than a thumb-visible minimum.
    func viewportRect(for visibleSource: CGRect, minimumSide: CGFloat = 6) -> CGRect {
        guard visibleSource.width > 0, visibleSource.height > 0 else { return .zero }
        var rect = CGRect(x: visibleSource.minX * scaleX, y: visibleSource.minY * scaleY,
                          width: visibleSource.width * scaleX, height: visibleSource.height * scaleY)
        if rect.width < minimumSide { rect = rect.insetBy(dx: (rect.width - minimumSide) / 2, dy: 0) }
        if rect.height < minimumSide { rect = rect.insetBy(dx: 0, dy: (rect.height - minimumSide) / 2) }
        return rect
    }

    /// The display point under a map point, clamped to the display.
    func sourcePoint(forMapPoint point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / scaleX, 0), sourceSize.width),
                y: min(max(point.y / scaleY, 0), sourceSize.height))
    }

    func mapPoint(forSourcePoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scaleX, y: point.y * scaleY)
    }

    /// Dragging the rectangle by `delta` on the map moves the view the same way over the display:
    /// the picture pans the opposite way, scaled from map points to canvas points.
    func canvasPan(forMapDrag delta: CGSize, viewportScale: CGFloat) -> CGSize {
        guard viewportScale.isFinite, viewportScale > 0 else { return .zero }
        return CGSize(width: -delta.width / scaleX * viewportScale, height: -delta.height / scaleY * viewportScale)
    }
}

/// When the mini map shows: only while part of the display is off screen and nothing covers the
/// corner. It appears when the view moves and fades `linger` seconds after it stops, unless a
/// finger is on it. Each method returns true when the caller should (re)start the fade timer.
struct MiniMapVisibility: Equatable {
    static let linger: Double = 3

    private(set) var shown = false
    private(set) var touching = false

    /// Zoom, pan, pointer follow, rotation or a mode change.
    mutating func viewportChanged(eligible: Bool) -> Bool {
        guard eligible else { shown = false; return false }
        shown = true
        return !touching
    }

    mutating func touch(_ active: Bool, eligible: Bool) -> Bool {
        touching = active
        if active { shown = eligible; return false }
        return shown
    }

    mutating func lingerExpired() {
        if !touching { shown = false }
    }

    /// The dock, keyboard or a sheet opened, the setting changed, or the view stopped cropping.
    mutating func eligibilityChanged(_ eligible: Bool) {
        if !eligible { shown = false; touching = false }
    }
}
