import Foundation
import CoreGraphics

/// Client-side prediction of the Mac pointer in capture-display logical points.
///
/// The host applies each relative move exactly (absolute CGEvent placement, no system
/// acceleration) and clamps it to the display, so the phone replays unacknowledged moves
/// with the same per-step clamp on top of the latest authoritative sample. Residual error
/// (physical mouse, app warps, rejected or lost moves) is blended out instead of snapping.
struct PointerPredictor {
    static let correctionTimeConstant: TimeInterval = 0.045
    static let snapDistance: CGFloat = 64
    static let pendingLimit = 512

    /// A relative delta, or an absolute placement (`moveTo`) that replaces the replayed point.
    private struct Pending { let ordinal: UInt64; let delta: CGSize; var target: CGPoint? = nil }

    private(set) var bounds: CGSize
    private(set) var authoritative: CGPoint?
    private(set) var acknowledged: UInt64 = 0
    private(set) var predicted: CGPoint?
    private var pending: [Pending] = []
    private var nextOrdinal: UInt64 = 1
    private var correction = CGVector.zero
    private var correctionAt: TimeInterval = 0

    init(bounds: CGSize) { self.bounds = bounds }

    var pendingCount: Int { pending.count }

    mutating func reset(bounds: CGSize) { self = PointerPredictor(bounds: bounds) }

    mutating func reserveOrdinal() -> UInt64 {
        defer { nextOrdinal &+= 1; if nextOrdinal == 0 { nextOrdinal = 1 } }
        return nextOrdinal
    }

    /// Call only for a move the control channel accepted for sending.
    mutating func applyLocalMove(ordinal: UInt64, delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        pending.append(Pending(ordinal: ordinal, delta: delta))
        if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
        if let predicted { self.predicted = clamp(CGPoint(x: predicted.x + delta.width, y: predicted.y + delta.height)) }
    }

    /// Call only for an absolute placement the control channel accepted for sending. The host
    /// places the pointer exactly there, so the drawn pointer jumps without a blended correction.
    mutating func applyLocalWarp(ordinal: UInt64, to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        pending.append(Pending(ordinal: ordinal, delta: .zero, target: point))
        if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
        predicted = clamp(point)
        correction = .zero
    }

    mutating func receive(point: CGPoint, applied: UInt64?, at now: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let before = displayed(at: now)
        let anchor = clamp(point)
        authoritative = anchor
        if let applied, applied > acknowledged { acknowledged = applied }
        pending.removeAll { $0.ordinal <= acknowledged }
        var replayed = anchor
        for move in pending {
            if let target = move.target {
                replayed = clamp(target)
            } else {
                replayed = clamp(CGPoint(x: replayed.x + move.delta.width, y: replayed.y + move.delta.height))
            }
        }
        predicted = replayed
        if let before, hypot(before.x - replayed.x, before.y - replayed.y) <= Self.snapDistance {
            correction = CGVector(dx: before.x - replayed.x, dy: before.y - replayed.y)
            correctionAt = now
        } else {
            correction = .zero
        }
    }

    func displayed(at now: TimeInterval) -> CGPoint? {
        guard let predicted else { return nil }
        let decay = Self.decay(since: correctionAt, now: now)
        return CGPoint(x: predicted.x + correction.dx * decay, y: predicted.y + correction.dy * decay)
    }

    /// True while the blended correction is still visibly moving the pointer.
    func correcting(at now: TimeInterval) -> Bool {
        let decay = Self.decay(since: correctionAt, now: now)
        return hypot(correction.dx, correction.dy) * decay > 0.05
    }

    private static func decay(since start: TimeInterval, now: TimeInterval) -> CGFloat {
        let elapsed = max(0, now - start)
        return CGFloat(exp(-elapsed / correctionTimeConstant))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width.nextDown),
                y: min(max(0, point.y), bounds.height.nextDown))
    }
}

/// Decides when the phone draws the pointer and whether it asks the host to hide the
/// captured cursor. Transitions prefer a brief duplicate over a missing pointer.
struct PointerOverlayPolicy {
    static let telemetryStaleAfter: TimeInterval = 0.8
    /// Keep drawing briefly after the host restores the captured cursor, while frames
    /// without it may still be in flight.
    static let restoreGrace: TimeInterval = 0.3

    private(set) var hostSupported = false
    private(set) var videoCursor = true
    private(set) var visible = false
    private(set) var shape: PointerShape = .arrow
    private(set) var lastTelemetryAt: TimeInterval = -.infinity
    private(set) var lastSample: UInt64 = 0
    private var restoredAt: TimeInterval = -.infinity

    mutating func reset() { self = PointerOverlayPolicy() }

    /// From each host `capture` action. Absence means a legacy host: captured cursor only.
    mutating func hostCapability(_ sync: PointerSync?, at now: TimeInterval) {
        guard let sync, sync.version == PointerSync.currentVersion, let cursor = sync.videoCursor else {
            if hostSupported || !videoCursor { reset() }
            return
        }
        hostSupported = true
        updateVideoCursor(cursor, at: now)
    }

    /// Returns false for an out-of-order or malformed sample.
    mutating func telemetry(_ sync: PointerSync, at now: TimeInterval) -> Bool {
        guard hostSupported, let sample = sync.sample, sample > lastSample,
              let cursor = sync.videoCursor, let visible = sync.visible else { return false }
        lastSample = sample
        lastTelemetryAt = now
        self.visible = visible
        shape = PointerShape(wire: sync.shape)
        updateVideoCursor(cursor, at: now)
        return true
    }

    func telemetryFresh(at now: TimeInterval) -> Bool {
        now >= lastTelemetryAt && now - lastTelemetryAt <= Self.telemetryStaleAfter
    }

    /// The heartbeat envelope, or nil for a legacy host. The host hides its cursor only after
    /// this phone has itself received fresh telemetry, and restores it when telemetry goes stale.
    func advertisement(at now: TimeInterval) -> PointerSync? {
        hostSupported ? PointerSync(overlay: telemetryFresh(at: now)) : nil
    }

    func shouldDraw(at now: TimeInterval, hasPosition: Bool) -> Bool {
        guard hostSupported, hasPosition, visible else { return false }
        return !videoCursor || (now >= restoredAt && now - restoredAt < Self.restoreGrace)
    }

    private mutating func updateVideoCursor(_ cursor: Bool, at now: TimeInterval) {
        if cursor && !videoCursor { restoredAt = now }
        videoCursor = cursor
    }
}
