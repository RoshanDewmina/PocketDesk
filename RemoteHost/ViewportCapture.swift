import CoreGraphics
import Foundation

/// The captured display in its own logical space (points from a top-left origin, as the phone's
/// viewport and `SCStreamConfiguration.sourceRect` use it) and its backing scale.
struct DisplayGeometry: Equatable {
    var size: CGSize
    var pointPixelScale: Double

    var bounds: CGRect { CGRect(origin: .zero, size: size) }
    var pixelWidth: Double { Double(size.width) * pointPixelScale }
    var pixelHeight: Double { Double(size.height) * pointPixelScale }

    var isValid: Bool {
        let minimum = Double(ViewportCapturePolicy.macroblock)
        return pointPixelScale.isFinite && pointPixelScale > 0 && pixelWidth.isFinite && pixelHeight.isFinite
            && pixelWidth >= minimum && pixelHeight >= minimum
    }
}

/// G4 (Docs/perf/PLAN-120FPS-AND-LOAD.md §4): what the stream covers for the phone's viewport.
///
/// Crop: the visible rect clamped to the display, plus `margin` on each side so a small pan needs no
/// re-crop, widened to the output's aspect (ScreenCaptureKit scales the crop into the fixed output, so
/// the phone's own aspect would come out stretched or letterboxed), at least `minimumLongEdgeFraction`
/// of the display's long edge, with an even pixel origin and a pixel size in whole macroblocks. A crop
/// that would cover `wholeDisplayCoverage` of the display or more is the whole display. While the
/// viewport stays inside the previous crop of the same size, that crop is kept.
///
/// Output: the whole-display size at the current rung, because a different frame size restarts the
/// VideoToolbox session with a key frame. It is not raised above the crop's pixels: when the crop has
/// fewer, the output drops to the crop's pixels (1:1), and that size is then held. A held size shrinks
/// again only when the crop falls below `shrinkBelow` of it (so the crop is scaled up by at most
/// 1/`shrinkBelow`, 11 %), grows only when the crop reaches `growFrom` of it, and returns to the
/// whole-display size with the whole display.
enum ViewportCapturePolicy {
    static let margin = 0.08
    static let wholeDisplayCoverage = 0.95
    static let minimumLongEdgeFraction = 0.25
    static let shrinkBelow = 0.9
    static let growFrom = 1.1
    static let macroblock = 16

    struct PixelRect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    static func wholeDisplay(_ display: DisplayGeometry, output: CapturePixelDimensions) -> CaptureRegion {
        CaptureRegion(epoch: 0, x: 0, y: 0, width: Double(display.size.width), height: Double(display.size.height),
                      outputWidth: output.width, outputHeight: output.height)
    }

    /// `output` is the whole-display output at the current rung; `previous` the region applied now, or
    /// nil when the output changed (quality, client pixels, restart) and the held size must not carry over.
    static func region(for viewport: ViewportRegion?, display: DisplayGeometry, output: CapturePixelDimensions,
                       tuning: StreamTuning, previous: CaptureRegion?) -> CaptureRegion {
        let whole = wholeDisplay(display, output: output)
        // Epoch 0 means the whole display on the wire, so a crop can never carry it.
        guard tuning.viewportCapture, let viewport, viewport.epoch != 0, viewport.zoom > 1,
              (try? viewport.validate()) != nil, display.isValid,
              output.width >= macroblock, output.height >= macroblock else { return whole }
        let visible = viewport.rect.intersection(display.bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0,
              let crop = crop(around: visible, display: display,
                              aspect: Double(output.width) / Double(output.height)) else { return whole }
        let scale = display.pointPixelScale
        var rect = CGRect(x: Double(crop.x) / scale, y: Double(crop.y) / scale,
                          width: Double(crop.width) / scale, height: Double(crop.height) / scale)
        var held: CapturePixelDimensions?
        if let previous, !previous.isWholeDisplay {
            held = CapturePixelDimensions(width: previous.outputWidth, height: previous.outputHeight)
            if previous.rect.size == rect.size, previous.rect.contains(visible) { rect = previous.rect }
        }
        let size = outputSize(source: CapturePixelDimensions(width: crop.width, height: crop.height),
                              whole: output, held: held)
        return CaptureRegion(epoch: viewport.epoch, x: Double(rect.minX), y: Double(rect.minY),
                             width: Double(rect.width), height: Double(rect.height),
                             outputWidth: size.width, outputHeight: size.height)
    }

    /// The crop in display pixels, or nil when it would be (nearly) the whole display.
    static func crop(around visible: CGRect, display: DisplayGeometry, aspect: Double) -> PixelRect? {
        let scale = display.pointPixelScale
        var width = Double(visible.width) * scale * (1 + 2 * margin)
        var height = Double(visible.height) * scale * (1 + 2 * margin)
        guard aspect.isFinite, aspect > 0, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        if width / height < aspect { width = height * aspect } else { height = width / aspect }
        let minimumLongEdge = minimumLongEdgeFraction * max(display.pixelWidth, display.pixelHeight)
        let longEdge = max(width, height)
        if longEdge < minimumLongEdge {
            width *= minimumLongEdge / longEdge
            height *= minimumLongEdge / longEdge
        }
        let alignedWidth = alignedUp(width)
        let alignedHeight = alignedUp(height)
        let displayArea = display.pixelWidth * display.pixelHeight
        guard Double(alignedWidth) <= display.pixelWidth, Double(alignedHeight) <= display.pixelHeight,
              Double(alignedWidth) * Double(alignedHeight) < wholeDisplayCoverage * displayArea else { return nil }
        let x = placed(center: Double(visible.midX) * scale, length: alignedWidth, limit: display.pixelWidth)
        let y = placed(center: Double(visible.midY) * scale, length: alignedHeight, limit: display.pixelHeight)
        return PixelRect(x: x, y: y, width: alignedWidth, height: alignedHeight)
    }

    /// The output for a crop of `source` pixels (see the type's rule); `held` is the previous crop's output.
    static func outputSize(source: CapturePixelDimensions, whole: CapturePixelDimensions,
                           held: CapturePixelDimensions?) -> CapturePixelDimensions {
        let target = source.width >= whole.width && source.height >= whole.height ? whole
            : CapturePixelDimensions(width: min(source.width, alignedDown(whole.width)),
                                     height: min(source.height, alignedDown(whole.height)))
        guard let held, held != whole, held.width > 0, held.height > 0,
              held.width <= whole.width, held.height <= whole.height else { return target }
        let ratio = min(Double(source.width) / Double(held.width), Double(source.height) / Double(held.height))
        return ratio < shrinkBelow || ratio >= growFrom ? target : held
    }

    /// A restart keeps the last viewport only while it still lies on the new display.
    static func isValid(_ viewport: ViewportRegion, for display: DisplayGeometry) -> Bool {
        guard (try? viewport.validate()) != nil, display.isValid else { return false }
        return display.bounds.insetBy(dx: -1, dy: -1).contains(viewport.rect)
    }

    /// An epoch-only change is echoed to the phone without touching the stream.
    static func needsReconfiguration(from applied: CaptureRegion, to next: CaptureRegion) -> Bool {
        applied.isWholeDisplay != next.isWholeDisplay || applied.rect != next.rect
            || applied.outputWidth != next.outputWidth || applied.outputHeight != next.outputHeight
    }

    private static func alignedUp(_ value: Double) -> Int {
        (Int((value - 1e-6).rounded(.up)) + macroblock - 1) / macroblock * macroblock
    }

    private static func alignedDown(_ value: Int) -> Int {
        value / macroblock * macroblock
    }

    private static func placed(center: Double, length: Int, limit: Double) -> Int {
        let start = min(max(0, center - Double(length) / 2), limit - Double(length))
        return Int(start.rounded(.down)) & ~1
    }
}

/// Serialises `SCStream.updateConfiguration`: one call in flight, viewport changes at most every
/// `minimumInterval` with the latest one applied on the trailing edge, quality changes without the wait.
/// The caller keeps the latest requested state; the gate only says when to apply it.
struct ConfigurationUpdateGate {
    enum Action: Equatable {
        case none
        case start
        case wait(until: TimeInterval)
    }

    static let minimumInterval: TimeInterval = 0.05
    private(set) var inFlight = false
    private(set) var pending = false
    private var lastStart: TimeInterval?

    mutating func request(at time: TimeInterval, immediate: Bool) -> Action {
        pending = true
        return next(at: time, immediate: immediate)
    }

    mutating func finished(at time: TimeInterval, immediate: Bool) -> Action {
        inFlight = false
        return next(at: time, immediate: immediate)
    }

    mutating func deadlineReached(at time: TimeInterval, immediate: Bool) -> Action {
        next(at: time, immediate: immediate)
    }

    private mutating func next(at time: TimeInterval, immediate: Bool) -> Action {
        guard pending, !inFlight else { return .none }
        if !immediate, let lastStart, time - lastStart < Self.minimumInterval {
            return .wait(until: lastStart + Self.minimumInterval)
        }
        pending = false
        inFlight = true
        lastStart = time
        return .start
    }
}
