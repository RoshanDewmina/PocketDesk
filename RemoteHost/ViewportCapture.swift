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
/// Phone-native rule (default; `CropPhoneNativeSwitch`):
/// - Engagement: only above 1 phone pixel per Mac point (at or below its mode's size the phone asks for
///   the whole display), when the crop below contains the visible rect and covers under
///   `wholeDisplayCoverage` of the display. That area rule is also the sharpness rule: the phone upscales
///   the whole stream when `zoom` exceeds its pixels per point, and a crop of at least 95 % of the display
///   could deliver at most sqrt(1 / 0.95), 2.6 %, more pixels per point than the whole stream at the same
///   budget, so it is not worth an encoder restart. Once the crop follows the viewport's aspect (not the
///   output's) every zoom past the phone's Fill size is under 95 %, so the crop engages whenever the phone
///   would otherwise upscale; below that it still engages as a cheaper, phone-native stream.
/// - Crop: the visible rect clamped to the display, plus `margin` on each side, at the viewport's own
///   aspect, at least `minimumLongEdgeFraction` of the display's long edge, an even pixel origin and a
///   pixel size in whole macroblocks, or the display's own edge where it spans it (a portrait crop spans
///   the height of a landscape display; the output is still in whole macroblocks). When the crop at phone-native
///   size would exceed the pixel budget, the margin shrinks (never the visible rect) until it fits.
/// - Output: the crop's pixels scaled by min(1, zoom / pointPixelScale), so the visible rect gets one
///   stream pixel per phone pixel (up to the display's own pixels), rounded up to macroblocks. Its only
///   cap is the area of `output`, the rung's whole-display output (so a size rung still bounds the
///   pixel rate and the encoder's level, which counts area), and `maximumEdge`; never `output`'s width or
///   height, so a portrait or panoramic crop keeps its shape. A held size stays while the new size is
///   within `shrinkBelow`...`growFrom` of it on both sides and fits the budget, so it is never more than
///   10 % under phone-native.
///
/// Previous rule (switch off): the crop widened to the output's aspect, a crop that would cover
/// `wholeDisplayCoverage` of the display or more is the whole display, and the output is the
/// whole-display size at the current rung, dropping to the crop's pixels (1:1) when it has fewer, held
/// until the crop falls below `shrinkBelow` of it or reaches `growFrom` of it.
///
/// Both: ScreenCaptureKit scales the crop into the output without preserving its aspect, the phone
/// places frames by the echoed rect, and while the viewport stays inside the previous crop of the same
/// size, that crop is kept.
enum ViewportCapturePolicy {
    static let margin = 0.08
    static let wholeDisplayCoverage = 0.95
    static let minimumLongEdgeFraction = 0.25
    static let shrinkBelow = 0.9
    static let growFrom = 1.1
    /// Crop-gain rule (`CropNearNativeSwitch`): a crop engages only when it delivers at least
    /// `cropGainEngage` times the stream pixels per Mac point of the whole display at the current rung,
    /// and once engaged stays while it delivers `cropGainRelease` times or more. A whole display streamed
    /// at its own pixels (1280x828 pt @2x as 2560x1656) cannot be beaten by any crop, yet build 20261002.2
    /// re-cropped it 10 times and recreated the encoder 7 times in 12 s of two-finger scrolling: each
    /// SCStream reconfiguration stalled the capture 100-460 ms and each output change restarted the
    /// encoder's rate control (b7-scroll NOTES, 2 Oct). The band keeps a zoom wobble from flipping the stream.
    static let cropGainEngage = 1.15
    static let cropGainRelease = 1.05
    static let macroblock = 16
    /// The H.264 and HEVC encoders' longest edge.
    static let maximumEdge = 4096

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
                       tuning: StreamTuning, previous: CaptureRegion?,
                       phoneNative: Bool = CropPhoneNativeSwitch.isOn,
                       nearNative: Bool = CropNearNativeSwitch.isOn,
                       keepBand: Bool = CropKeepBandSwitch.isOn) -> CaptureRegion {
        let whole = wholeDisplay(display, output: output)
        // Epoch 0 means the whole display on the wire, so a crop can never carry it.
        guard tuning.viewportCapture, let viewport, viewport.epoch != 0, viewport.zoom > 1,
              (try? viewport.validate()) != nil, display.isValid,
              output.width >= macroblock, output.height >= macroblock else { return whole }
        let visible = viewport.rect.intersection(display.bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return whole }
        let found = phoneNative
            ? phoneNativeCrop(around: visible, display: display, zoom: viewport.zoom, budget: output)
            : crop(around: visible, display: display, aspect: Double(output.width) / Double(output.height))
        guard let crop = found else { return whole }
        let scale = display.pointPixelScale
        var rect = CGRect(x: Double(crop.x) / scale, y: Double(crop.y) / scale,
                          width: Double(crop.width) / scale, height: Double(crop.height) / scale)
        var source = CapturePixelDimensions(width: crop.width, height: crop.height)
        var held: CapturePixelDimensions?
        if let previous, !previous.isWholeDisplay {
            held = CapturePixelDimensions(width: previous.outputWidth, height: previous.outputHeight)
            if previous.rect.contains(visible),
               previous.rect.size == rect.size || (keepBand && keepsCrop(previous.rect.size, for: rect.size)) {
                rect = previous.rect
                source = CapturePixelDimensions(width: Int((previous.rect.width * scale).rounded()),
                                                height: Int((previous.rect.height * scale).rounded()))
            }
        }
        let size = phoneNative
            ? phoneNativeOutputSize(source: source, zoom: viewport.zoom, display: display, budget: output, held: held)
            : outputSize(source: source, whole: output, held: held)
        if nearNative, phoneNative, rect.width > 0, display.size.width > 0 {
            let gain = (Double(size.width) / rect.width) / (Double(output.width) / display.size.width)
            let engaged = previous.map { !$0.isWholeDisplay } ?? false
            if gain < (engaged ? cropGainRelease : cropGainEngage) { return whole }
        }
        return CaptureRegion(epoch: viewport.epoch, x: Double(rect.minX), y: Double(rect.minY),
                             width: Double(rect.width), height: Double(rect.height),
                             outputWidth: size.width, outputHeight: size.height)
    }

    /// Source pixels per displayed phone pixel across the visible rect: 1 is phone-native, below 1 the
    /// phone upscales. Nil without a viewport.
    static func deliveredSharpness(region: CaptureRegion, viewport: ViewportRegion?,
                                   display: DisplayGeometry) -> Double? {
        let width = region.isWholeDisplay ? Double(display.size.width) : region.width
        guard let viewport, viewport.zoom.isFinite, viewport.zoom > 0, width.isFinite, width > 0,
              region.outputWidth > 0 else { return nil }
        let value = Double(region.outputWidth) / width / viewport.zoom
        return value.isFinite ? value : nil
    }

    /// The phone-native rule's crop in display pixels (see the type), or nil for the whole display.
    static func phoneNativeCrop(around visible: CGRect, display: DisplayGeometry, zoom: Double,
                                budget: CapturePixelDimensions) -> PixelRect? {
        guard var crop = crop(around: visible, display: display, expansion: 1 + 2 * margin) else { return nil }
        let steps = 16
        var step = 0
        while step < steps, area(phoneNativeTarget(source: CapturePixelDimensions(width: crop.width, height: crop.height),
                                                   zoom: zoom, display: display)) > area(budget) {
            step += 1
            let expansion = 1 + 2 * margin * Double(steps - step) / Double(steps)
            guard let smaller = self.crop(around: visible, display: display, expansion: expansion) else { break }
            crop = smaller
        }
        return crop
    }

    private static func crop(around visible: CGRect, display: DisplayGeometry, expansion: Double) -> PixelRect? {
        let scale = display.pointPixelScale
        var width = Double(visible.width) * scale * expansion
        var height = Double(visible.height) * scale * expansion
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let minimumLongEdge = minimumLongEdgeFraction * max(display.pixelWidth, display.pixelHeight)
        let longEdge = max(width, height)
        if longEdge < minimumLongEdge {
            width *= minimumLongEdge / longEdge
            height *= minimumLongEdge / longEdge
        }
        let alignedWidth = min(alignedUp(width), Int(display.pixelWidth.rounded(.down)))
        let alignedHeight = min(alignedUp(height), Int(display.pixelHeight.rounded(.down)))
        let displayArea = display.pixelWidth * display.pixelHeight
        guard alignedWidth >= macroblock, alignedHeight >= macroblock,
              Double(alignedWidth) * Double(alignedHeight) < wholeDisplayCoverage * displayArea else { return nil }
        let x = placed(center: Double(visible.midX) * scale, length: alignedWidth, limit: display.pixelWidth)
        let y = placed(center: Double(visible.midY) * scale, length: alignedHeight, limit: display.pixelHeight)
        let pixels = CGRect(x: x, y: y, width: alignedWidth, height: alignedHeight)
        let shown = CGRect(x: visible.minX * scale, y: visible.minY * scale,
                           width: visible.width * scale, height: visible.height * scale).insetBy(dx: 1e-6, dy: 1e-6)
        guard pixels.contains(shown) else { return nil }
        return PixelRect(x: x, y: y, width: alignedWidth, height: alignedHeight)
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

    /// One stream pixel per phone pixel across the crop, up to the crop's own pixels, in whole macroblocks
    /// (a crop spanning the display's full edge can be up to 15 pixels short of one).
    static func phoneNativeTarget(source: CapturePixelDimensions, zoom: Double,
                                  display: DisplayGeometry) -> CapturePixelDimensions {
        let fraction = min(1, zoom / display.pointPixelScale)
        return CapturePixelDimensions(width: alignedUp(Double(source.width) * fraction),
                                      height: alignedUp(Double(source.height) * fraction))
    }

    /// The phone-native rule's output (see the type); `held` is the previous crop's output.
    static func phoneNativeOutputSize(source: CapturePixelDimensions, zoom: Double, display: DisplayGeometry,
                                      budget: CapturePixelDimensions,
                                      held: CapturePixelDimensions?) -> CapturePixelDimensions {
        var target = phoneNativeTarget(source: source, zoom: zoom, display: display)
        if area(target) > area(budget) {
            target = shrunk(target, by: (Double(area(budget)) / Double(area(target))).squareRoot())
        }
        if max(target.width, target.height) > maximumEdge {
            target = shrunk(target, by: Double(maximumEdge) / Double(max(target.width, target.height)))
        }
        guard let held, held.width >= macroblock, held.height >= macroblock,
              held.width % macroblock == 0, held.height % macroblock == 0, area(held) <= area(budget),
              max(held.width, held.height) <= maximumEdge else { return target }
        let ratios = [Double(target.width) / Double(held.width), Double(target.height) / Double(held.height)]
        return ratios.allSatisfy({ $0 >= shrinkBelow && $0 < growFrom }) ? held : target
    }

    private static func area(_ size: CapturePixelDimensions) -> Int { size.width * size.height }

    private static func shrunk(_ size: CapturePixelDimensions, by fraction: Double) -> CapturePixelDimensions {
        CapturePixelDimensions(width: max(macroblock, alignedDown(Int(Double(size.width) * fraction))),
                               height: max(macroblock, alignedDown(Int(Double(size.height) * fraction))))
    }

    /// Keep-band rule (`CropKeepBandSwitch`): a crop that still contains the visible rect is kept while
    /// the crop the viewport would get now is within `shrinkBelow`...`growFrom` of it on both sides, so a
    /// zoom wobble, or the visible rect shrinking by the safe insets at a display edge, is not a new crop.
    static func keepsCrop(_ previous: CGSize, for next: CGSize) -> Bool {
        guard previous.width > 0, previous.height > 0, next.width > 0, next.height > 0 else { return false }
        let ratios = [next.width / previous.width, next.height / previous.height]
        return ratios.allSatisfy { $0 >= shrinkBelow && $0 < growFrom }
    }

    /// Only the phone's regular heartbeat states its viewport. LTR acknowledgements and pointer probes
    /// also travel as heartbeats, without one, and must not drop the crop between two regular ones.
    static func describesViewport(_ heartbeat: RemoteAction) -> Bool {
        heartbeat.isRegularPhoneHeartbeat
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

/// Kill switch for the phone-native crop (`defaults write <bundle id> PocketDeskCropPhoneNative -bool NO`,
/// then relaunch the host). Off restores the crop widened to the output's aspect and the output capped at
/// the rung's whole-display width and height.
enum CropPhoneNativeSwitch {
    static let defaultsKey = "PocketDeskCropPhoneNative"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}

/// Kill switch for the near-native rule (`defaults write <bundle id> PocketDeskCropNearNative -bool NO`, then
/// relaunch the host). Off crops whenever the phone would upscale at all, as build 20261002.2 did.
enum CropNearNativeSwitch {
    static let defaultsKey = "PocketDeskCropNearNative"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}

/// Kill switch for the keep-band rule (`defaults write <bundle id> PocketDeskCropKeepBand -bool NO`, then
/// relaunch the host). Off keeps a crop only while the viewport asks for exactly the same size.
enum CropKeepBandSwitch {
    static let defaultsKey = "PocketDeskCropKeepBand"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
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
