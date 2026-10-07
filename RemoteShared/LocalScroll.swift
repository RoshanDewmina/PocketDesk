import CoreGraphics
import Foundation
import simd

/// Phone flag for optimistic local scroll (`defaults write <phone bundle id> PocketDeskLocalScroll -bool YES`
/// or the launch argument `-PocketDeskLocalScroll YES`, then relaunch). Off by default until a device A/B.
/// Off, the phone never asks the Mac for `scrollRegion` and never shifts the picture.
enum LocalScrollSwitch {
    static let defaultsKey = "PocketDeskLocalScroll"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// The scrollable content under the Mac pointer, in display-local Mac points (top-left origin), on
/// `capture` status for a phone that asked for `SessionFeature.localScroll`.
struct ScrollRegionFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Smaller areas are list cells and buttons, not something worth sliding.
    static let minimumSide = 24.0

    init(_ rect: CGRect) {
        x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func validate() throws {
        let limit = ViewportRegion.maximumPoints
        guard [x, y, width, height].allSatisfy({ $0.isFinite }), abs(x) <= limit, abs(y) <= limit,
              width > 0, height > 0, width <= limit, height <= limit else { throw RemoteError.invalidMessage }
    }

    /// Accessibility frames are global (top-left of the main display); the phone works in the captured
    /// display's own points. Nil when the area lies off that display or is too small to matter.
    static func displayLocal(_ global: CGRect, display: CGRect) -> ScrollRegionFrame? {
        guard [global.minX, global.minY, global.width, global.height].allSatisfy({ $0.isFinite }),
              display.width > 0, display.height > 0 else { return nil }
        let clipped = global.intersection(display)
        guard !clipped.isNull, clipped.width >= minimumSide, clipped.height >= minimumSide else { return nil }
        return ScrollRegionFrame(clipped.offsetBy(dx: -display.minX, dy: -display.minY).integral)
    }
}

/// The shader's clip rect and shift, in the drawn picture's own 0...1 coordinates (top-left origin).
/// `shift.xy` moves the content, `shift.zw` is half a picture pixel, so the vacated strip repeats the
/// region's own edge pixels rather than whatever lies beyond it.
struct LocalScrollUniform: Equatable {
    var rect: SIMD4<Float>
    var shift: SIMD4<Float>
    static let off = LocalScrollUniform(rect: .zero, shift: .zero)
}

/// Optimistic local scroll (LATENCY-PLAN §2.1): while a finger scrolls, the phone slides the scroll
/// area of the picture it already has, and the next frame from the Mac replaces the slide outright.
/// Main thread only. Deltas are the Mac points the phone sent; momentum is the Mac's own and never echoed.
struct LocalScrollEcho {
    /// The slide stops growing once it holds this many frame intervals of finger motion.
    static let capFrames = 2.0
    static let defaultFrameInterval: TimeInterval = 1.0 / 30
    static let frameIntervalRange: ClosedRange<TimeInterval> = (1.0 / 120)...(1.0 / 15)
    /// Original frames in a row that show no change inside the region while the finger moves.
    static let unchangedFrameLimit = 3
    /// The Mac shows a scroll only a round trip after it, so frames this soon after the gesture began
    /// say nothing about the content's end until one of them has shown a change.
    static let startGrace: TimeInterval = 0.4
    /// Only frames this soon after a sent delta can be expected to show it.
    static let motionWindow: TimeInterval = 0.25
    /// A slide no frame has replaced by then is dropped: the Mac sends no frame while nothing changes
    /// (content already at its end, a lift with no coast), and a shifted picture must not linger.
    static let staleAfter: TimeInterval = 0.2
    /// Sparse luma grid side used to tell whether the region changed between frames.
    static let sampleGrid = 24

    let enabled: Bool
    private(set) var region: CGRect?
    private(set) var offset: CGSize = .zero
    private(set) var stopped = false
    private(set) var frameInterval = defaultFrameInterval
    private(set) var gestureActive = false
    /// The Mac pointer when the gesture began was outside the region the Mac last reported, which is
    /// then about another area (it arrives a round trip after the pointer moved).
    private(set) var outsideRegion = false
    private var gesturePointer: CGPoint?
    private var gestureStartedAt: TimeInterval = 0
    private var echoStartedAt: TimeInterval?
    private var lastDeltaAt: TimeInterval?
    private var lastOriginalFrameAt: TimeInterval?
    private var unchangedFrames = 0
    private var changeSeen = false

    init(enabled: Bool) { self.enabled = enabled }

    var isEchoing: Bool { offset != .zero }
    var capDuration: TimeInterval { Self.capFrames * frameInterval }
    var wantsChangeCheck: Bool { enabled && region != nil && gestureActive && !stopped && !outsideRegion }

    /// The Mac's latest region; nil when it reports none. True when a shifted picture must be redrawn.
    @discardableResult
    mutating func setRegion(_ rect: CGRect?) -> Bool {
        guard enabled else { return false }
        let valid = rect.flatMap { r -> CGRect? in
            [r.minX, r.minY, r.width, r.height].allSatisfy({ $0.isFinite }) && r.width > 0 && r.height > 0 ? r : nil
        }
        guard valid != region else { return false }
        region = valid
        if let gesturePointer { outsideRegion = !(valid?.contains(gesturePointer) ?? false) }
        return dropOffset()
    }

    /// A finger scroll the phone just sent; `pointer` is where the phone believes the Mac pointer is (Mac
    /// points), nil when unknown. True when the slide moved and the picture needs a redraw.
    mutating func scrolled(_ delta: CGSize, phase: String, pointer: CGPoint? = nil, at now: TimeInterval) -> Bool {
        guard enabled else { return false }
        switch phase {
        case "began":
            gestureActive = true; gestureStartedAt = now
            stopped = false; unchangedFrames = 0; changeSeen = false
            gesturePointer = pointer.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
            outsideRegion = gesturePointer.map { !(region?.contains($0) ?? false) } ?? false
        case "changed":
            guard gestureActive else { return false }
        default:
            // Lift, cancel and every momentum phase: the Mac coasts on its own, so echoing it doubles motion.
            gestureActive = false
            gesturePointer = nil
            return false
        }
        guard let region, !stopped, !outsideRegion, delta.width.isFinite, delta.height.isFinite, delta != .zero else { return false }
        lastDeltaAt = now
        let started = echoStartedAt ?? now
        guard now - started <= capDuration else { return false }
        echoStartedAt = started
        let moved = CGSize(width: min(region.width / 2, max(-region.width / 2, offset.width + delta.width)),
                           height: min(region.height / 2, max(-region.height / 2, offset.height + delta.height)))
        guard moved != offset else { return false }
        offset = moved
        return true
    }

    /// A slide that no frame replaced within `staleAfter`. True when it was dropped and needs a redraw.
    mutating func expire(at now: TimeInterval) -> Bool {
        guard let echoStartedAt, now - echoStartedAt >= Self.staleAfter else { return false }
        return dropOffset()
    }

    /// Any newer picture replaces the slide outright, with no blend. True when a slide was showing.
    @discardableResult
    mutating func frameArrived(original: Bool, at now: TimeInterval) -> Bool {
        if original {
            if let last = lastOriginalFrameAt, Self.frameIntervalRange.contains(now - last) {
                frameInterval = frameInterval * 0.75 + (now - last) * 0.25
            }
            lastOriginalFrameAt = now
        }
        return dropOffset()
    }

    /// Whether a slide may be drawn now without making a real frame wait. A slide draw occupies a
    /// drawable until the display shows it, so a frame landing in that refresh would show one refresh
    /// later; slides are drawn only when the next frame is not due within `refreshesClear` refreshes,
    /// or when the stream has gone quiet (no frame for two intervals), where none is due at all.
    static let refreshesClear = 1.5
    func redrawAllowed(at now: TimeInterval, refresh: TimeInterval) -> Bool {
        guard let last = lastOriginalFrameAt, refresh.isFinite, refresh > 0 else { return true }
        let due = last + frameInterval
        return now >= last + 2 * frameInterval || now + Self.refreshesClear * refresh <= due
    }

    /// After an original frame is drawn: whether its picture inside the region differs from the previous
    /// one. Three unchanged frames while the finger moves mean the content is at its end.
    mutating func observed(changed: Bool, at now: TimeInterval) {
        guard wantsChangeCheck else { return }
        if changed { changeSeen = true; unchangedFrames = 0; return }
        guard let lastDeltaAt, now - lastDeltaAt <= Self.motionWindow,
              changeSeen || now - gestureStartedAt >= Self.startGrace else { return }
        unchangedFrames += 1
        if unchangedFrames >= Self.unchangedFrameLimit {
            stopped = true
            dropOffset()
        }
    }

    /// `picture` is the Mac-point rect the drawn frame covers and `pixels` its displayed size. Nil draws
    /// the picture unshifted.
    func uniform(picture: CGRect, pixels: CGSize) -> LocalScrollUniform? {
        guard enabled, !stopped, !outsideRegion, offset != .zero, let region,
              picture.width > 0, picture.height > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let clip = region.intersection(picture)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return nil }
        return LocalScrollUniform(
            rect: SIMD4(Float((clip.minX - picture.minX) / picture.width), Float((clip.minY - picture.minY) / picture.height),
                        Float(clip.width / picture.width), Float(clip.height / picture.height)),
            shift: SIMD4(Float(offset.width / picture.width), Float(offset.height / picture.height),
                         Float(0.5 / pixels.width), Float(0.5 / pixels.height)))
    }

    /// Cell centers of the change-detection grid inside `rect` (picture 0...1 coordinates).
    static func samplePoints(in rect: CGRect) -> [CGPoint] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let side = CGFloat(sampleGrid)
        return (0..<sampleGrid).flatMap { row in
            (0..<sampleGrid).map { column in
                CGPoint(x: rect.minX + (CGFloat(column) + 0.5) / side * rect.width,
                        y: rect.minY + (CGFloat(row) + 0.5) / side * rect.height)
            }
        }
    }

    /// A few strong luma differences, or a broad small one. Encoder noise on still content stays below
    /// both; nil when the two grids cannot be compared.
    static func regionChanged(_ previous: [UInt8], _ current: [UInt8]) -> Bool? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var strong = 0, total = 0
        for (a, b) in zip(previous, current) {
            let difference = abs(Int(a) - Int(b))
            total += difference
            if difference > 24 { strong += 1 }
        }
        return strong >= 3 || Double(total) / Double(current.count) > 2
    }

    @discardableResult
    private mutating func dropOffset() -> Bool {
        let dropped = offset != .zero
        offset = .zero
        echoStartedAt = nil
        return dropped
    }
}
