import Foundation
import CoreGraphics

/// Pointer telemetry v1: one optional envelope on control actions.
///
/// Phone `heartbeat`: presence advertises support; `overlay == true` asks the host to
/// omit the cursor from video because the phone is drawing it from fresh telemetry.
/// Phone `move` and `moveTo`: `move` is a per-epoch ordinal so the host can acknowledge it.
/// Host `capture`: presence advertises support; `videoCursor` reports the applied capture setting.
/// Host `pointer`: an authoritative sample in capture-display logical points. Hosts send this
/// action only to a phone that advertised support, because older phones reject unknown actions.
struct PointerSync: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = PointerSync.currentVersion
    var overlay: Bool? = nil
    var move: UInt64? = nil
    var videoCursor: Bool? = nil
    var x: Double? = nil
    var y: Double? = nil
    var visible: Bool? = nil
    var shape: String? = nil
    var applied: UInt64? = nil
    var sample: UInt64? = nil

    func validate(action: String) throws {
        guard version == Self.currentVersion else { throw RemoteError.invalidMessage }
        let positional = x != nil || y != nil || visible != nil || shape != nil || applied != nil || sample != nil
        switch action {
        case "heartbeat":
            guard overlay != nil, move == nil, videoCursor == nil, !positional else { throw RemoteError.invalidMessage }
        case "move", "moveTo":
            guard let move, move > 0, overlay == nil, videoCursor == nil, !positional else { throw RemoteError.invalidMessage }
        case "capture":
            guard videoCursor != nil, overlay == nil, move == nil, !positional else { throw RemoteError.invalidMessage }
        case "pointer":
            guard let x, let y, x.isFinite, y.isFinite, (0...20000).contains(x), (0...20000).contains(y),
                  visible != nil, videoCursor != nil, sample != nil, overlay == nil, move == nil,
                  let shape, (1...32).contains(shape.utf8.count),
                  shape.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
            else { throw RemoteError.invalidMessage }
        default:
            throw RemoteError.invalidMessage
        }
    }
}

extension RemoteAction {
    /// Returns true when this is a complete `pointer` action, which bypasses the legacy action list.
    func validatePointerSync() throws -> Bool {
        guard action == "pointer" || pointerSync != nil else { return false }
        guard let pointerSync else { throw RemoteError.invalidMessage }
        try pointerSync.validate(action: action)
        guard action == "pointer" else { return false }
        // A `pointer` action skips the legacy checks, so every other field must be absent.
        guard x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty, interaction == nil,
              pointerLocatorSupported == nil, pointerProbe == nil, pointerLocation == nil, streamQuality == nil,
              textFocusProbe == nil, textFocusEditable == nil
        else { throw RemoteError.invalidMessage }
        return true
    }
}

/// Cursor shapes the phone can draw natively. Unknown wire values decode as `.unknown`
/// (drawn as the arrow) so a newer host can never end an older phone's session.
enum PointerShape: String, CaseIterable, Equatable {
    case arrow, iBeam, iBeamVertical, pointingHand, openHand, closedHand, crosshair
    case resizeLeftRight, resizeUpDown, resizeNorthWestSouthEast, resizeNorthEastSouthWest
    case notAllowed, contextualMenu, dragCopy, dragLink, disappearingItem
    case zoomIn, zoomOut, unknown

    init(wire: String?) {
        self = wire.flatMap(PointerShape.init(rawValue:)) ?? .unknown
    }
}

/// Host-side sampling and capture-cursor policy. Pure so it can be tested without AppKit.
struct HostPointerTelemetryPolicy {
    static let capabilityLifetime: TimeInterval = 1.0
    static let keepalive: TimeInterval = 0.25
    /// A just-posted move precedes WindowServer's cursor update, by hundreds of milliseconds on a
    /// loaded Mac (29 Sep clip: the real cursor ran 300-500 ms behind the phone). Report the injected
    /// point until the observed cursor reaches it or this much time passes; catching up ends the
    /// bridge early, so a physical mouse is masked only while the cursor is genuinely late.
    static let injectionSettle: TimeInterval = 0.5
    static let injectionTolerance: CGFloat = 0.5
    /// After falling back to the captured cursor, wait before hiding it again to avoid capture churn.
    static let rehideCooldown: TimeInterval = 2.0

    private struct Snapshot: Equatable {
        var x: Double, y: Double, visible: Bool, shape: PointerShape, applied: UInt64, videoCursor: Bool
    }

    private(set) var capableUntil: TimeInterval = -.infinity
    private(set) var overlayRequested = false
    private(set) var appliedMove: UInt64 = 0
    private(set) var samplesSent: UInt64 = 0
    private var lastSent: Snapshot?
    private var lastSentAt: TimeInterval = -.infinity
    private var lastKnown = CGPoint.zero
    private var injection: (point: CGPoint, at: TimeInterval)?
    private var fallbackAt: TimeInterval = -.infinity

    mutating func reset() { self = HostPointerTelemetryPolicy() }

    /// Call for every phone heartbeat. A heartbeat without the envelope withdraws capability.
    mutating func phoneHeartbeat(_ sync: PointerSync?, at now: TimeInterval) {
        guard let sync, sync.version == PointerSync.currentVersion else {
            capableUntil = -.infinity
            overlayRequested = false
            return
        }
        capableUntil = now + Self.capabilityLifetime
        overlayRequested = sync.overlay == true
    }

    /// Every move in the current epoch is acknowledged once processed, accepted or not,
    /// so the phone never replays a rejected delta forever.
    mutating func moveProcessed(ordinal: UInt64?) {
        if let ordinal, ordinal > appliedMove { appliedMove = ordinal }
    }

    mutating func moveInjected(at point: CGPoint, now: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite else { return }
        injection = (point, now)
    }

    func streaming(at now: TimeInterval) -> Bool { now < capableUntil }

    func wantsCursorHidden(at now: TimeInterval) -> Bool {
        streaming(at: now) && overlayRequested && samplesSent > 0 && now - fallbackAt >= Self.rehideCooldown
    }

    /// Record that video went from hidden back to a captured cursor.
    mutating func noteFallback(at now: TimeInterval) { fallbackAt = now }

    /// `observed` is display-local, or nil when the cursor is on another display.
    mutating func sample(observed: CGPoint?, shape: PointerShape, videoCursor: Bool,
                         at now: TimeInterval) -> PointerSync? {
        guard streaming(at: now) else { return nil }
        var point = observed
        if let injection, now >= injection.at, now - injection.at < Self.injectionSettle {
            let caughtUp = observed.map {
                hypot($0.x - injection.point.x, $0.y - injection.point.y) <= Self.injectionTolerance
            } ?? false
            if caughtUp { self.injection = nil } else { point = injection.point }
        }
        if let point, point.x.isFinite, point.y.isFinite { lastKnown = point }
        let snapshot = Snapshot(x: Self.quantized(lastKnown.x), y: Self.quantized(lastKnown.y),
                                visible: point != nil, shape: shape, applied: appliedMove,
                                videoCursor: videoCursor)
        guard snapshot != lastSent || now - lastSentAt >= Self.keepalive || now < lastSentAt else { return nil }
        lastSent = snapshot
        lastSentAt = now
        samplesSent &+= 1
        return PointerSync(videoCursor: videoCursor, x: snapshot.x, y: snapshot.y,
                           visible: snapshot.visible, shape: shape.rawValue,
                           applied: appliedMove, sample: samplesSent)
    }

    /// Maps a global CoreGraphics point into the captured display, matching the input driver's clamp.
    static func displayPoint(_ global: CGPoint, in frame: CGRect) -> CGPoint? {
        guard global.x.isFinite, global.y.isFinite, frame.width > 0, frame.height > 0,
              global.x >= frame.minX, global.x < frame.maxX,
              global.y >= frame.minY, global.y < frame.maxY else { return nil }
        return CGPoint(x: global.x - frame.minX, y: global.y - frame.minY)
    }

    private static func quantized(_ value: CGFloat) -> Double {
        (Double(value) * 64).rounded() / 64
    }
}
