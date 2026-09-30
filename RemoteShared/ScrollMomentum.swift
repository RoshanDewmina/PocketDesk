import Foundation
import CoreGraphics

/// Wire phases that follow a scroll gesture's `ended`, on the same stream. Sent only to a Mac
/// that advertises `SessionFeature.momentumScroll`.
enum ScrollMomentumPhase: String, CaseIterable {
    case began = "momentumBegan"
    case changed = "momentumChanged"
    case ended = "momentumEnded"
}

/// The phone's half of native inertia: it measures how fast the fingers were moving when they
/// lifted, then emits a decaying series of deltas the Mac posts as momentum-phase scroll events,
/// so apps rubber-band and coast the way they do for a real trackpad.
///
/// Deltas are in Mac points, the same units the gesture's own scroll deltas use.
struct ScrollMomentum {
    /// Only the last moments before lift describe the flick.
    static let velocityWindow: TimeInterval = 0.08
    /// Fingers that paused before lifting leave no momentum.
    static let liftPause: TimeInterval = 0.06
    /// Below this lift speed a scroll just stops, in points per second.
    static let minimumLiftSpeed: CGFloat = 220
    static let maximumSpeed: CGFloat = 7_000
    /// Momentum ends below this speed, in points per second.
    static let stopSpeed: CGFloat = 18
    static let maximumDuration: TimeInterval = 2.5
    /// UIScrollView's normal deceleration: the speed kept per millisecond.
    static let decelerationPerMs: CGFloat = 0.998

    enum Step: Equatable {
        case changed(CGSize)
        case ended
    }

    private var samples: [(time: TimeInterval, delta: CGSize)] = []
    private(set) var velocity: CGVector?
    private var startedAt: TimeInterval = 0
    private var lastStep: TimeInterval = 0
    private var residual: CGSize = .zero

    var isRunning: Bool { velocity != nil }

    mutating func record(_ delta: CGSize, at time: TimeInterval) {
        guard time.isFinite, delta.width.isFinite, delta.height.isFinite else { return }
        samples.append((time, delta))
        samples.removeAll { time - $0.time > Self.velocityWindow }
    }

    mutating func resetSamples() {
        samples.removeAll(keepingCapacity: true)
    }

    /// The fingers' velocity at `time`, or nil when there is no flick worth continuing.
    func liftVelocity(at time: TimeInterval) -> CGVector? {
        guard let last = samples.last, time - last.time <= Self.liftPause else { return nil }
        let recent = samples.filter { time - $0.time <= Self.velocityWindow }
        guard let first = recent.first else { return nil }
        let span = max(time - first.time, 1.0 / 120.0)
        let dx = recent.reduce(CGFloat.zero) { $0 + $1.delta.width }
        let dy = recent.reduce(CGFloat.zero) { $0 + $1.delta.height }
        var vector = CGVector(dx: dx / span, dy: dy / span)
        let speed = hypot(vector.dx, vector.dy)
        guard speed.isFinite, speed >= Self.minimumLiftSpeed else { return nil }
        if speed > Self.maximumSpeed {
            vector = CGVector(dx: vector.dx * Self.maximumSpeed / speed, dy: vector.dy * Self.maximumSpeed / speed)
        }
        return vector
    }

    /// Starts coasting from the lift velocity. Returns false when the fingers didn't flick.
    mutating func start(at time: TimeInterval) -> Bool {
        defer { resetSamples() }
        guard let lift = liftVelocity(at: time) else { return false }
        velocity = lift
        startedAt = time
        lastStep = time
        residual = .zero
        return true
    }

    /// The next delta, or `.ended` once the coast has run out. Nil while not running or when no
    /// time has passed.
    mutating func step(at time: TimeInterval) -> Step? {
        guard let current = velocity, time.isFinite else { return nil }
        let dt = time - lastStep
        guard dt > 0 else { return nil }
        let decay = pow(Self.decelerationPerMs, CGFloat(dt * 1000))
        let next = CGVector(dx: current.dx * decay, dy: current.dy * decay)
        lastStep = time
        guard hypot(next.dx, next.dy) >= Self.stopSpeed, time - startedAt < Self.maximumDuration else {
            velocity = nil
            return .ended
        }
        velocity = next
        // Distance covered while decaying from `current` to `next` over `dt`.
        let travel = (1 - decay) / -log(Self.decelerationPerMs) / 1000
        let x = current.dx * travel + residual.width
        let y = current.dy * travel + residual.height
        let unit: CGFloat = 64
        let sent = CGSize(width: (x * unit).rounded(.towardZero) / unit, height: (y * unit).rounded(.towardZero) / unit)
        residual = CGSize(width: x - sent.width, height: y - sent.height)
        return .changed(sent)
    }

    /// Stops at once. Returns true when a running coast was cut short and needs its end sent.
    mutating func cancel() -> Bool {
        resetSamples()
        guard velocity != nil else { return false }
        velocity = nil
        return true
    }
}
