import Foundation
import CoreGraphics

public enum ViewportMode: String, Equatable, CaseIterable {
    case fill
    case fit

    public var toggled: ViewportMode { self == .fill ? .fit : .fill }
}

/// Per-edge obstruction of the canvas: display corners, the sensor housing,
/// the home indicator and an open keyboard. Always taken from real scene geometry.
public struct ViewportInsets: Equatable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = ViewportInsets()

    fileprivate var sanitized: ViewportInsets {
        func clean(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        return ViewportInsets(top: clean(top), left: clean(left), bottom: clean(bottom), right: clean(right))
    }
}

/// Maps a captured source image into a client canvas without depending on a UI framework.
///
/// The canvas is the whole scene, edge to edge. Fill covers the canvas; Fit shows the whole
/// source inside the safe rectangle. In both modes panning is limited so every source edge
/// can be brought fully inside the safe rectangle, never beyond it. `zoom` is relative to
/// the selected mode's baseline scale and `offset` is measured from its baseline origin.
public struct ViewportTransform {
    public private(set) var sourceSize: CGSize
    public private(set) var canvasSize: CGSize
    public private(set) var safeInsets: ViewportInsets
    public private(set) var mode: ViewportMode
    public private(set) var zoom: CGFloat
    public private(set) var offset: CGPoint
    private var insetReturn: InsetReturn?

    private struct InsetReturn {
        let insets: ViewportInsets
        let offset: CGPoint
        let zoom: CGFloat
        let resultingOffset: CGPoint
        let resultingZoom: CGFloat
        let mode: ViewportMode
    }

    public init(sourceSize: CGSize, canvasSize: CGSize, mode: ViewportMode = .fill,
                zoom: CGFloat = 1, offset: CGPoint = CGPoint(), safeInsets: ViewportInsets = .zero) {
        self.sourceSize = Self.validSize(sourceSize)
        self.canvasSize = Self.validSize(canvasSize)
        self.safeInsets = safeInsets.sanitized
        self.mode = mode
        self.zoom = 1
        self.offset = CGPoint()
        self.zoom = clampedZoom(zoom)
        self.offset = clampedOffset(Self.finitePoint(offset))
    }

    /// The part of the canvas that is never covered by hardware or system UI.
    public var safeRect: CGRect {
        let insets = safeInsets
        let rect = CGRect(x: insets.left, y: insets.top,
                          width: canvasSize.width - insets.left - insets.right,
                          height: canvasSize.height - insets.top - insets.bottom)
        guard rect.width > 1, rect.height > 1 else { return CGRect(origin: .zero, size: canvasSize) }
        return rect
    }

    /// The scale that fits the full source inside the safe rectangle.
    public var fitScale: CGFloat {
        let safe = safeRect.size
        guard sourceSize.width > 0, sourceSize.height > 0, safe.width > 0, safe.height > 0 else { return 0 }
        let value = min(safe.width / sourceSize.width, safe.height / sourceSize.height)
        return value.isFinite && value > 0 ? value : 0
    }

    /// The scale that covers the whole canvas, edge to edge, without stretching the source.
    public var fillScale: CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 0 }
        let value = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        return value.isFinite && value > 0 ? value : 0
    }

    public var baselineScale: CGFloat { mode == .fill ? fillScale : fitScale }

    /// Fill may be pinched down to the Fit size; both modes zoom in to 3× the Fill size.
    public var zoomRange: ClosedRange<CGFloat> {
        let base = baselineScale
        guard base > 0, fitScale > 0 else { return 1...3 }
        let lower = mode == .fill ? min(1, fitScale / base) : 1
        let upper = max(3, 3 * fillScale / base)
        return lower...upper
    }

    /// The current source-to-canvas scale after applying user zoom.
    public var scale: CGFloat {
        let value = baselineScale * zoom
        return value.isFinite && value > 0 ? value : 0
    }

    public var isAtBaseline: Bool { zoom == 1 && offset == CGPoint() }

    /// The source's rendered rectangle in canvas coordinates.
    public var contentRect: CGRect {
        guard scale > 0 else { return CGRect() }
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        guard size.width.isFinite, size.height.isFinite else { return CGRect() }
        let origin = baselineOrigin(for: size)
        return CGRect(x: origin.x + offset.x, y: origin.y + offset.y, width: size.width, height: size.height)
    }

    /// Converts a canvas point to a source point. Points in letterbox bands have no source mapping.
    public func sourcePoint(fromView point: CGPoint) -> CGPoint? {
        guard Self.isFinite(point), scale > 0,
              point.x >= 0, point.x <= canvasSize.width,
              point.y >= 0, point.y <= canvasSize.height else { return nil }
        let rect = contentRect
        guard point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        let mapped = CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
        guard Self.isFinite(mapped) else { return nil }
        return CGPoint(x: min(max(mapped.x, 0), sourceSize.width),
                       y: min(max(mapped.y, 0), sourceSize.height))
    }

    /// Converts a source point to its canvas position. Invalid inputs produce `.zero`.
    public func viewPoint(fromSource point: CGPoint) -> CGPoint {
        guard Self.isFinite(point), scale > 0 else { return CGPoint() }
        let rect = contentRect
        let mapped = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        return Self.isFinite(mapped) ? mapped : CGPoint()
    }

    /// Changes zoom while keeping the source point under `anchor` in place when possible.
    public mutating func setZoom(_ zoom: CGFloat, anchoredAt anchor: CGPoint) {
        let sourceAnchor = sourcePoint(fromView: anchor)
        self.zoom = clampedZoom(zoom)
        guard let sourceAnchor, Self.isFinite(anchor), scale > 0 else {
            offset = clampedOffset(offset)
            return
        }
        place(sourceAnchor, at: anchor)
    }

    /// A deliberate View-mode double tap zooms around its location. A subsequent
    /// double tap returns to a safe Fit overview rather than leaving cropped edges.
    public mutating func toggleZoom(anchoredAt anchor: CGPoint) {
        guard Self.isFinite(anchor), baselineScale > 0,
              sourcePoint(fromView: anchor) != nil else { return }
        if zoom > 1.05 {
            setMode(.fit)
        } else {
            let targetScale = max(scale * 2, fillScale)
            setZoom(targetScale / baselineScale, anchoredAt: anchor)
        }
    }

    /// Ends a pinch. Pinching Fill below its own size and releasing nearer Fit switches to
    /// Fit; releasing a Fit zoom close to the Fill size switches to Fill. Returns true when
    /// the mode changed.
    @discardableResult
    public mutating func settleZoom() -> Bool {
        guard scale > 0, fitScale > 0, fillScale > 0 else { return false }
        switch mode {
        case .fill where zoom < 1:
            let midpoint = (fitScale + fillScale) / 2
            if scale < midpoint { setMode(.fit); return true }
            let center = CGPoint(x: safeRect.midX, y: safeRect.midY)
            setZoom(1, anchoredAt: center)
            return false
        case .fit where fillScale > fitScale * 1.02:
            let ratio = scale / fillScale
            if ratio > 0.94 && ratio < 1.08 { setMode(.fill); return true }
            return false
        default:
            return false
        }
    }

    /// Moves the rendered source by a canvas-space translation.
    public mutating func pan(by translation: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        offset = clampedOffset(CGPoint(x: offset.x + translation.width, y: offset.y + translation.height))
    }

    /// Pans only as far as needed to bring a source point into the usable canvas.
    /// The visible rectangle is in full-canvas coordinates and may exclude safe areas
    /// or a dock. Returns true only when the offset actually changes.
    @discardableResult
    public mutating func reveal(sourcePoint: CGPoint, in visibleRect: CGRect,
                                margin: CGFloat = 32) -> Bool {
        // When the entire source already fits, following would needlessly move
        // the overview out of the safe area to clear transient chrome.
        guard scale > fitScale * 1.001, Self.isFinite(sourcePoint), scale > 0,
              sourcePoint.x >= 0, sourcePoint.x <= sourceSize.width,
              sourcePoint.y >= 0, sourcePoint.y <= sourceSize.height,
              margin.isFinite, margin >= 0,
              visibleRect.origin.x.isFinite, visibleRect.origin.y.isFinite,
              visibleRect.width.isFinite, visibleRect.height.isFinite,
              visibleRect.width > 0, visibleRect.height > 0,
              contentRect.width > 0, contentRect.height > 0 else { return false }

        let usable = visibleRect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !usable.isNull, usable.width > 0, usable.height > 0 else { return false }

        let insetX = min(margin, usable.width / 4)
        let insetY = min(margin, usable.height / 4)
        let position = viewPoint(fromSource: sourcePoint)
        let target = CGPoint(
            x: min(max(position.x, usable.minX + insetX), usable.maxX - insetX),
            y: min(max(position.y, usable.minY + insetY), usable.maxY - insetY)
        )
        let deltaX = abs(target.x - position.x) > 0.000_001 ? target.x - position.x : 0
        let deltaY = abs(target.y - position.y) > 0.000_001 ? target.y - position.y : 0
        guard deltaX != 0 || deltaY != 0 else { return false }
        let previous = offset
        // Automatic following may use a smaller unobstructed rectangle than the
        // safe area (for example while the dock is open). Clamp to that rectangle
        // so a pointer near the source edge can actually clear the obstruction.
        offset = clampedOffset(CGPoint(x: offset.x + deltaX, y: offset.y + deltaY), in: usable)
        return abs(offset.x - previous.x) > 0.000_001 || abs(offset.y - previous.y) > 0.000_001
    }

    /// Pans, without zooming, only as far as needed to bring a source rect inside the visible rectangle,
    /// inset by `margin`. A rect larger than that keeps its leading edges in view. Unlike pointer follow
    /// this also works at the Fit size, where the keyboard's chrome can cover the lower desktop. With
    /// `transient`, closing the obstruction that caused it (the keyboard) still returns to the prior view.
    @discardableResult
    public mutating func reveal(sourceRect rect: CGRect, in visibleRect: CGRect,
                                margin: CGFloat = 16, transient: Bool = false) -> Bool {
        guard scale > 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, margin.isFinite, margin >= 0,
              visibleRect.origin.x.isFinite, visibleRect.origin.y.isFinite,
              visibleRect.width.isFinite, visibleRect.height.isFinite,
              contentRect.width > 0, contentRect.height > 0 else { return false }
        let source = rect.standardized.intersection(CGRect(origin: .zero, size: sourceSize))
        let usable = visibleRect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !source.isNull, !usable.isNull, usable.width > 0, usable.height > 0 else { return false }
        let target = usable.insetBy(dx: min(margin, usable.width / 4), dy: min(margin, usable.height / 4))
        let shown = CGRect(x: contentRect.minX + source.minX * scale, y: contentRect.minY + source.minY * scale,
                           width: source.width * scale, height: source.height * scale)
        func delta(_ low: CGFloat, _ high: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
            if high - low > max - min || low < min { return min - low }
            if high > max { return max - high }
            return 0
        }
        let deltaX = delta(shown.minX, shown.maxX, target.minX, target.maxX)
        let deltaY = delta(shown.minY, shown.maxY, target.minY, target.maxY)
        guard abs(deltaX) > 0.000_001 || abs(deltaY) > 0.000_001 else { return false }
        let previous = offset
        offset = clampedOffset(CGPoint(x: offset.x + deltaX, y: offset.y + deltaY), in: usable)
        let moved = abs(offset.x - previous.x) > 0.000_001 || abs(offset.y - previous.y) > 0.000_001
        if moved, transient, let pending = insetReturn, pending.resultingOffset == previous, pending.resultingZoom == zoom {
            insetReturn = InsetReturn(insets: pending.insets, offset: pending.offset, zoom: pending.zoom,
                                      resultingOffset: offset, resultingZoom: zoom, mode: pending.mode)
        }
        return moved
    }

    /// Scene or source geometry changed (rotation, window resize, new display).
    /// A baseline view stays at its baseline; a manual view keeps its normalized focal point.
    public mutating func resize(sourceSize: CGSize, canvasSize: CGSize) {
        resize(sourceSize: sourceSize, canvasSize: canvasSize, safeInsets: safeInsets)
    }

    public mutating func resize(sourceSize: CGSize, canvasSize: CGSize, safeInsets: ViewportInsets) {
        let wasBaseline = isAtBaseline
        let focus = normalizedFocus
        self.sourceSize = Self.validSize(sourceSize)
        self.canvasSize = Self.validSize(canvasSize)
        self.safeInsets = safeInsets.sanitized
        insetReturn = nil
        zoom = clampedZoom(zoom)
        guard !wasBaseline, let focus, scale > 0 else {
            offset = clampedOffset(CGPoint())
            return
        }
        placeFocus(focus)
    }

    /// Only the obstructed edges changed, for example the keyboard opened. The source point
    /// at the centre of the old safe rectangle moves to the centre of the new one, and closing
    /// the obstruction again returns exactly to the previous view if nothing moved meanwhile.
    public mutating func updateSafeInsets(_ insets: ViewportInsets) {
        let insets = insets.sanitized
        guard insets != safeInsets else { return }
        if let pending = insetReturn, pending.insets == insets, pending.mode == mode,
           pending.resultingOffset == offset, pending.resultingZoom == zoom {
            safeInsets = insets
            insetReturn = nil
            zoom = clampedZoom(pending.zoom)
            offset = clampedOffset(pending.offset)
            return
        }
        let previous = (insets: safeInsets, offset: offset, zoom: zoom)
        let focus = normalizedFocus
        safeInsets = insets
        zoom = clampedZoom(zoom)
        if let focus, scale > 0, !(mode == .fit && zoom == 1) {
            placeFocus(focus)
        } else {
            offset = clampedOffset(CGPoint())
        }
        insetReturn = InsetReturn(insets: previous.insets, offset: previous.offset, zoom: previous.zoom,
                                  resultingOffset: offset, resultingZoom: zoom, mode: mode)
    }

    /// The part of the source drawn on the canvas, in source points. Empty when nothing is drawn.
    public var visibleSourceRect: CGRect {
        let rect = contentRect
        let visible = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard scale > 0, !visible.isNull, visible.width > 0, visible.height > 0 else { return .zero }
        return CGRect(x: (visible.minX - rect.minX) / scale, y: (visible.minY - rect.minY) / scale,
                      width: visible.width / scale, height: visible.height / scale)
    }

    /// True when part of the source is off screen, so a navigator has something to show.
    public var isCropped: Bool {
        let visible = visibleSourceRect
        guard sourceSize.width > 0, sourceSize.height > 0, visible.width > 0 else { return false }
        return visible.width < sourceSize.width - 0.5 || visible.height < sourceSize.height - 0.5
    }

    /// Pans (without zooming) so a source point sits at the centre of the safe rectangle, as far
    /// as the pan limits allow. Used by the mini map's tap-to-jump.
    public mutating func center(onSourcePoint point: CGPoint) {
        guard Self.isFinite(point), scale > 0, sourceSize.width > 0, sourceSize.height > 0 else { return }
        let target = CGPoint(x: min(max(point.x, 0), sourceSize.width), y: min(max(point.y, 0), sourceSize.height))
        let safe = safeRect
        insetReturn = nil
        place(target, at: CGPoint(x: safe.midX, y: safe.midY))
    }

    /// Covers the canvas while preserving the source aspect ratio.
    public mutating func fill() { setMode(.fill) }

    /// Shows the whole source inside the safe rectangle.
    public mutating func fit() { setMode(.fit) }

    public mutating func setMode(_ mode: ViewportMode) {
        self.mode = mode
        insetReturn = nil
        zoom = 1
        offset = clampedOffset(CGPoint())
    }

    // MARK: - Geometry helpers

    private var normalizedFocus: CGPoint? {
        let safe = safeRect
        guard let point = sourcePoint(fromView: CGPoint(x: safe.midX, y: safe.midY)),
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        return CGPoint(x: point.x / sourceSize.width, y: point.y / sourceSize.height)
    }

    private mutating func placeFocus(_ focus: CGPoint) {
        let safe = safeRect
        place(CGPoint(x: focus.x * sourceSize.width, y: focus.y * sourceSize.height),
              at: CGPoint(x: safe.midX, y: safe.midY))
    }

    private mutating func place(_ source: CGPoint, at canvasPoint: CGPoint) {
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = baselineOrigin(for: size)
        offset = clampedOffset(CGPoint(x: canvasPoint.x - origin.x - source.x * scale,
                                       y: canvasPoint.y - origin.y - source.y * scale))
    }

    /// Fill is centred on the whole canvas so its crop is symmetric; Fit is centred in the
    /// safe rectangle so the complete desktop clears the sensor housing and display corners.
    private func baselineOrigin(for size: CGSize) -> CGPoint {
        let frame = mode == .fill ? CGRect(origin: .zero, size: canvasSize) : safeRect
        return CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
    }

    private func clampedOffset(_ proposed: CGPoint, in visibleRect: CGRect? = nil) -> CGPoint {
        guard scale > 0 else { return CGPoint() }
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        guard size.width.isFinite, size.height.isFinite else { return CGPoint() }
        let origin = baselineOrigin(for: size)
        let safe = visibleRect ?? safeRect
        let x = Self.clampedOrigin(origin.x + proposed.x, length: size.width,
                                   safeMin: safe.minX, safeMax: safe.maxX) - origin.x
        let y = Self.clampedOrigin(origin.y + proposed.y, length: size.height,
                                   safeMin: safe.minY, safeMax: safe.maxY) - origin.y
        // Rounding must not turn an unmoved baseline into a "manual" view.
        return CGPoint(x: abs(x) < 0.000_000_1 ? 0 : x, y: abs(y) < 0.000_000_1 ? 0 : y)
    }

    /// Content no longer than the safe span is centred in it. Longer content may slide
    /// until either of its edges reaches the matching safe edge, so every part is reachable.
    private static func clampedOrigin(_ value: CGFloat, length: CGFloat,
                                      safeMin: CGFloat, safeMax: CGFloat) -> CGFloat {
        let span = safeMax - safeMin
        guard value.isFinite, length.isFinite, span.isFinite else { return safeMin }
        if length <= span + 0.000_001 { return safeMin + (span - length) / 2 }
        return min(max(value, safeMax - length), safeMin)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        let range = zoomRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func validSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return CGSize() }
        return size
    }

    private static func finitePoint(_ point: CGPoint) -> CGPoint {
        isFinite(point) ? point : CGPoint()
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

// MARK: - Viewport capture (G4)

/// What the phone asks the Mac to capture (Docs/perf/PLAN-120FPS-AND-LOAD.md §4): a rect in display
/// points with a top-left origin, the convention `moveTo` and direct touch use, and the device pixels
/// that rect covers on screen at the current zoom.
struct ViewportCaptureRequest: Equatable {
    var rect: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
    /// Device pixels per display point.
    var zoom: Double
    /// The display the rect was measured on; a request for any other display is never sent.
    var displaySize: CGSize

    func region(epoch: UInt64) -> ViewportRegion {
        ViewportRegion(epoch: epoch, x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width),
                       height: Double(rect.height), pixelWidth: pixelWidth, pixelHeight: pixelHeight, zoom: zoom)
    }

    /// The same centre showing `factor` times the width and height, kept on the display. Zoom and pixels
    /// stay as they are: the Mac reads them only to tell a magnified view from a reduced one.
    func widened(by factor: CGFloat) -> ViewportCaptureRequest {
        let display = CGRect(origin: .zero, size: displaySize)
        let width = min(rect.width * factor, display.width), height = min(rect.height * factor, display.height)
        let x = min(max(rect.midX - width / 2, 0), display.maxX - width)
        let y = min(max(rect.midY - height / 2, 0), display.maxY - height)
        return ViewportCaptureRequest(rect: CGRect(x: x, y: y, width: width, height: height),
                                      pixelWidth: pixelWidth, pixelHeight: pixelHeight, zoom: zoom,
                                      displaySize: displaySize)
    }
}

extension ViewportTransform {
    /// Requested rects move in 1/64 pt steps, like direct touch, so rounding noise is never a change.
    static let captureQuantum: CGFloat = 64

    static func wholeDisplayRect(for displaySize: CGSize) -> CGRect {
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else { return .zero }
        return CGRect(origin: .zero, size: displaySize)
    }

    /// Where a display-point rect lands when the whole display is drawn in `displayRect`, such as the
    /// mini map. Each axis scales on its own, so a rounded map size cannot shift the rect.
    static func placement(of rect: CGRect, displaySize: CGSize, in displayRect: CGRect) -> CGRect {
        guard isFinite(rect), isFinite(displayRect), displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else { return .zero }
        let scaleX = displayRect.width / displaySize.width
        let scaleY = displayRect.height / displaySize.height
        return CGRect(x: displayRect.minX + rect.minX * scaleX, y: displayRect.minY + rect.minY * scaleY,
                      width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// A display-point rect in the picture container, which sits on `contentRect` and positions the
    /// pointer glyph the same way: display points × `scale`.
    func pictureRect(fromSource rect: CGRect) -> CGRect {
        guard scale > 0, Self.isFinite(rect) else { return .zero }
        return CGRect(x: rect.minX * scale, y: rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// A display-point rect on the canvas: the same mapping as `viewPoint(fromSource:)`.
    func viewRect(fromSource rect: CGRect) -> CGRect {
        guard scale > 0, Self.isFinite(rect) else { return .zero }
        let content = contentRect
        return pictureRect(fromSource: rect).offsetBy(dx: content.minX, dy: content.minY)
    }

    /// The display points under a canvas rect, not clamped to the display.
    func sourceRect(fromView rect: CGRect) -> CGRect {
        guard scale > 0, Self.isFinite(rect) else { return .zero }
        let content = contentRect
        return CGRect(x: (rect.minX - content.minX) / scale, y: (rect.minY - content.minY) / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    /// Where decoded frames sit inside the picture container. A cropped capture's frames show only the
    /// region the Mac echoed for them, so they are placed by it, never by the viewport asked for last;
    /// whole-display capture fills the container exactly as before viewport capture existed.
    func picturePlacement(for region: CaptureRegion?) -> CGRect {
        guard let region, !region.isWholeDisplay else { return CGRect(origin: .zero, size: contentRect.size) }
        return pictureRect(fromSource: region.rect)
    }

    /// The same placement on the canvas.
    func framePlacement(for region: CaptureRegion?) -> CGRect {
        guard let region, !region.isWholeDisplay else { return contentRect }
        return viewRect(fromSource: region.rect)
    }

    /// Fit, and any zoom at or below the mode's own size, asks for the whole display; so does a zoom
    /// that still shows all of it.
    var requestsWholeDisplay: Bool { zoom <= 1 || !isCropped }

    /// What to ask the Mac to capture now; nil until the viewport has a display, a canvas and a scale.
    func captureRequest(displayScale: CGFloat) -> ViewportCaptureRequest? {
        guard displayScale.isFinite, displayScale > 0, scale > 0 else { return nil }
        let display = Self.wholeDisplayRect(for: sourceSize)
        let rect = requestsWholeDisplay ? display : Self.captureQuantized(visibleSourceRect, within: display)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let pixelsPerPoint = scale * displayScale
        let range = ViewportRegion.zoomRange
        let rounded = (Double(pixelsPerPoint) * 10_000).rounded() / 10_000
        let pixelZoom = min(max(rounded, range.lowerBound), range.upperBound)
        return ViewportCaptureRequest(rect: rect, pixelWidth: Self.capturePixels(rect.width * pixelsPerPoint),
                                      pixelHeight: Self.capturePixels(rect.height * pixelsPerPoint),
                                      zoom: pixelZoom, displaySize: sourceSize)
    }

    private static func captureQuantized(_ rect: CGRect, within display: CGRect) -> CGRect {
        func step(_ value: CGFloat, limit: CGFloat) -> CGFloat {
            min(max(0, (value * captureQuantum).rounded() / captureQuantum), limit)
        }
        let minX = step(rect.minX, limit: display.maxX), maxX = step(rect.maxX, limit: display.maxX)
        let minY = step(rect.minY, limit: display.maxY), maxY = step(rect.maxY, limit: display.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func capturePixels(_ value: CGFloat) -> Int {
        let range = ViewportRegion.pixelRange
        guard value.isFinite else { return range.lowerBound }
        return Int(min(max(value.rounded(), CGFloat(range.lowerBound)), CGFloat(range.upperBound)))
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
    }
}
