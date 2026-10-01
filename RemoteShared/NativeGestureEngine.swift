import Foundation
import CoreGraphics

enum NativeSwipeDirection { case left, right, up, down }

/// When a direct touch shows the Precision Tap loupe instead of pressing the button.
enum PrecisionTapTrigger: String, CaseIterable, Identifiable {
    case off
    /// A still touch-and-hold opens the loupe; a slide still drags.
    case hold
    /// Every single-finger touch opens the loupe at once.
    case always

    static let key = "precisionTap"
    var id: String { rawValue }
}

enum PrecisionPhase: Equatable { case began, moved, ended, cancelled }

/// Commands emitted by direct phone touches. `move` is already in host logical points.
enum NativeGestureCommand {
    case move(CGSize)
    /// Direct touch: put the Mac pointer under this canvas point. The receiver maps it through
    /// the viewport and rejects points outside the picture (letterbox bands).
    case pointTo(CGPoint)
    case scroll(delta: CGSize, phase: String, stream: String)
    case click(count: Int)
    case secondaryClick
    /// A three-finger tap: the Mac's middle mouse button.
    case middleClick
    /// A mouse's Back or Forward side button.
    case auxiliaryClick(AuxiliaryMouseButton)
    case workspaceSwipe(direction: NativeSwipeDirection)
    case dragBegan(id: String, count: Int)
    case dragEnded(id: String)
    case zoom(factor: CGFloat, anchor: CGPoint)
    /// Sent once when a recognized pinch ends or is cancelled, so the view can settle.
    case zoomEnded
    case zoomToggle(anchor: CGPoint)
    case navigate(factor: CGFloat, anchor: CGPoint, translation: CGSize)
    case pan(CGSize)
    /// Precision Tap: the finger's canvas point. The receiver owns the loupe and decides on `ended`
    /// whether to click; `cancelled` never clicks.
    case precision(PrecisionPhase, CGPoint)
}

/// A deterministic, single-owner touch arbiter. Call `update` with the entire active
/// direct-touch set after each UIKit event, and `tick` while touches are active.
///
/// Trackpad (default) moves the Mac pointer relatively. Direct places it under the finger:
/// a tap clicks there, a drag (or a stationary hold) presses the button there and follows the
/// finger, and two-finger gestures act on what is under the fingers. View mode stays local.
final class NativeGestureEngine {
    struct Touch: Equatable {
        let id: UInt64
        let point: CGPoint
    }

    /// Movement that turns a direct tap into a click-drag. Larger than the trackpad's
    /// pointer threshold so an ordinary tap is not mistaken for a drag.
    static let directSlop: CGFloat = 10
    /// Finger-pad settling is tap motion, not pointer travel. Never replay it when sliding starts.
    static let trackpadSlop: CGFloat = 8
    /// A still direct touch held this long presses the button, like touch-and-hold on a screen.
    static let directHoldDelay: TimeInterval = 0.5
    /// A still direct touch held this long opens the Precision Tap loupe, before it could press.
    static let precisionHoldDelay: TimeInterval = 0.3
    /// A three-finger tap: every finger lifts within this time and moves less than `tapTravel`.
    static let threeFingerTapDuration: TimeInterval = 0.45
    static let threeFingerTapTravel: CGFloat = 12
    /// A third finger landing this soon after the first, with this little movement so far,
    /// still starts a three-finger gesture.
    static let workspaceLandingWindow: TimeInterval = 0.25
    static let workspaceLandingSlop: CGFloat = 12
    /// Ignore resting-finger jitter when comparing each finger's direction.
    static let multiFingerMotionSlop: CGFloat = 2
    /// One moving finger may just lead a scroll. Allow its partner to catch up before
    /// recognizing a deliberate pinch with a stationary anchor.
    static let anchoredPinchDelay: TimeInterval = 0.12
    /// Well inside the Mac's 0.5 s expiry for a silent scroll stream.
    static let scrollKeepAliveInterval: TimeInterval = 0.25

    var onCommand: (NativeGestureCommand) -> Bool
    var onPointerMotionEnded: () -> Void = {}
    /// The Mac posts momentum phases (`SessionFeature.momentumScroll`): a flicked scroll coasts.
    var momentumEnabled = false
    /// The Mac runs the coast from the lift velocity (`SessionFeature.hostMomentum`): one message
    /// starts it, the next touch ends it, and nothing in between crosses the link.
    var hostMomentumEnabled = false
    private var momentum = ScrollMomentum()
    private var momentumStream: String?
    private var hostCoasting = false
    /// After this the Mac has certainly finished on its own; a touch then has nothing to end.
    private var hostCoastUntil: TimeInterval = 0
    /// Keep calling `tick` while true, even with no touches down.
    var hasMomentum: Bool { momentumStream != nil && !hostCoasting }
    private var pointerMotionActive = false

    private enum Mode { case candidate, pointer, multiCandidate, scroll, zoom, pan, drag, precision, workspaceCandidate, workspaceFired, blocked }
    private var mode: Mode = .blocked
    private var active: [UInt64: CGPoint] = [:]
    private var firstPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastMotionTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var maxDistance: CGFloat = 0
    private var workspaceSequence = false
    private var workspaceOrigins: [UInt64: CGPoint] = [:]
    private var hadTwo = false
    private var multiTapEligible = false
    private var multiOrigins: [UInt64: CGPoint] = [:]
    private var multiStartTime: TimeInterval = 0
    private var multiStartCenter: CGPoint = .zero
    private var multiLastCenter: CGPoint = .zero
    private var multiStartDistance: CGFloat = 0
    private var multiLastDistance: CGFloat = 0
    private var scrollID: String?
    private var dragID: String?
    private var zoomActive = false
    private var precisionActive = false
    private var precisionDeclined = false
    private var residual: CGSize = .zero
    private var lastTap: (time: TimeInterval, point: CGPoint)?
    private var secondTap = false
    private var lastUpdateTime: TimeInterval = 0
    private var lastScrollSent: TimeInterval = 0
    /// The canvas point a direct touch targets: where it landed, or the first tap of a double tap.
    private var directPoint: CGPoint = .zero
    private var workspaceTapEligible = false
    private var workspaceSwipeFired = false

    private(set) var enabled: Bool
    private(set) var panMode: Bool
    private(set) var direct = false
    private(set) var precision: PrecisionTapTrigger = .off
    private(set) var revision: UInt64
    private var sensitivity: CGFloat
    private var pointerScale: CGFloat
    private var doubleClickInterval: TimeInterval
    private var gestureSensitivity: CGFloat = 1
    private var gestureScale: CGFloat = 1

    init(enabled: Bool, panMode: Bool, revision: UInt64, sensitivity: CGFloat,
         pointerScale: CGFloat, doubleClickInterval: TimeInterval, direct: Bool = false,
         onCommand: @escaping (NativeGestureCommand) -> Bool) {
        self.enabled = enabled
        self.panMode = panMode
        self.direct = direct
        self.revision = revision
        self.sensitivity = Self.safeSensitivity(sensitivity)
        self.pointerScale = Self.safeScale(pointerScale)
        self.doubleClickInterval = Self.safeInterval(doubleClickInterval)
        self.onCommand = onCommand
    }

    var hasActiveTouches: Bool { !active.isEmpty }

    func configure(enabled: Bool, panMode: Bool, revision: UInt64, sensitivity: CGFloat,
                   pointerScale: CGFloat, doubleClickInterval: TimeInterval, direct: Bool = false,
                   precision: PrecisionTapTrigger = .off) {
        if self.enabled != enabled || self.panMode != panMode || self.revision != revision || self.direct != direct
            || self.precision != precision {
            stopMomentum()
            cancel()
            // A surviving physical contact must lift before it can start a new command.
            mode = .blocked
            lastTap = nil
        }
        self.enabled = enabled
        self.panMode = panMode
        self.direct = direct
        self.precision = precision
        self.revision = revision
        self.sensitivity = Self.safeSensitivity(sensitivity)
        self.pointerScale = Self.safeScale(pointerScale)
        self.doubleClickInterval = Self.safeInterval(doubleClickInterval)
    }

    func update(_ touches: [Touch], at time: TimeInterval, cancelled: Bool = false) {
        guard time.isFinite else { return }
        lastUpdateTime = time
        if cancelled {
            cancel()
            active = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, $0.point) })
            return
        }
        let next = Dictionary(uniqueKeysWithValues: touches.filter {
            $0.point.x.isFinite && $0.point.y.isFinite
        }.map { ($0.id, $0.point) })
        let oldCount = active.count
        let count = next.count
        if oldCount == 0 && count > 0 { stopMomentum() }
        if oldCount == 0 {
            active = next
            guard count > 0 else { return }
            guard count <= 3, let point = next.values.first else { mode = .blocked; return }
            startTime = time
            lastMotionTime = time
            precisionDeclined = false
            firstPoint = point
            lastPoint = point
            maxDistance = 0
            residual = .zero
            gestureSensitivity = sensitivity
            gestureScale = pointerScale
            hadTwo = count == 2
            if count == 3 {
                beginWorkspace(next, eligible: enabled && !panMode)
            } else if count == 2 {
                multiTapEligible = true
                beginMulti(next)
                lastTap = nil
            } else {
                secondTap = (panMode || enabled) && lastTap.map {
                    time >= $0.time && time - $0.time <= (panMode ? 0.35 : doubleClickInterval) &&
                    distance(point, $0.point) <= 24
                } ?? false
                if panMode {
                    mode = .pan
                } else if direct && enabled {
                    // The second tap of a double tap lands exactly on the first, as a mouse would.
                    directPoint = secondTap ? lastTap?.point ?? point : point
                    if onCommand(.pointTo(directPoint)) {
                        mode = .candidate
                        if precision == .always && !secondTap { beginPrecision(at: point) }
                    } else {
                        mode = .blocked
                        secondTap = false
                        lastTap = nil
                    }
                } else {
                    mode = .candidate
                }
            }
            return
        }

        if workspaceSequence {
            if count == 0 {
                if workspaceTapEligible && !workspaceSwipeFired && enabled && !panMode &&
                    time - startTime <= Self.threeFingerTapDuration {
                    fireMiddleClick()
                }
                resetSequence()
            } else if count == 3 && Set(next.keys) == Set(workspaceOrigins.keys) {
                trackWorkspaceTravel(next)
                processWorkspace(next, at: time)
            } else {
                // Uneven lifting may still finish a tap; a new or replaced finger cannot.
                if count > 3 || !Set(next.keys).isSubset(of: Set(workspaceOrigins.keys)) {
                    workspaceTapEligible = false
                } else {
                    trackWorkspaceTravel(next)
                }
                mode = .blocked
            }
            active = next
            return
        }
        if count >= 3 {
            // Fingers land tens of milliseconds apart and the first ones drift a few points
            // meanwhile, so a barely started pointer move or scroll can still become a swipe.
            let settling = mode == .candidate || mode == .multiCandidate ||
                ((mode == .pointer || mode == .scroll) && maxDistance <= Self.workspaceLandingSlop)
            let eligible = count == 3 && enabled && !panMode && settling &&
                time - startTime <= Self.workspaceLandingWindow
            cancelOwnedCommand()
            beginWorkspace(next, eligible: eligible)
            active = next
            return
        }
        if count > oldCount && count == 2 {
            if hadTwo {
                // A completed multi-touch gesture owns the whole physical sequence.
                mode = .blocked
                active = next
                return
            }
            multiTapEligible = mode == .candidate
            cancelOwnedCommand()
            hadTwo = true
            lastTap = nil
            beginMulti(next)
            active = next
            return
        }

        if hadTwo {
            if count == 2 { processMulti(next, at: time) }
            if count < 2 && (mode == .scroll || mode == .zoom) { finishContinuous(cancelled: false) }
            if count == 0 {
                if mode == .multiCandidate && multiTapEligible && enabled && !panMode &&
                    time - startTime <= 0.55 && maxDistance <= 8 {
                    // Direct touch right-clicks what is under the fingers, never where the
                    // pointer happened to be.
                    if !direct || onCommand(.pointTo(multiStartCenter)) {
                        _ = onCommand(.secondaryClick)
                    }
                }
                resetSequence()
            } else if count == 1 {
                // Keep ownership until the last finger lifts, even on uneven removal.
                if oldCount == 2 {
                    lastPoint = next.values.first!
                } else if let point = next.values.first {
                    maxDistance = max(maxDistance, distance(point, lastPoint))
                    if maxDistance > 8 { mode = .blocked }
                }
                if mode != .multiCandidate { mode = .blocked }
            }
            active = next
            return
        }

        if count == 0 {
            if panMode && mode == .pan && maxDistance <= 4 && time - startTime <= 0.55 {
                if secondTap {
                    _ = onCommand(.zoomToggle(anchor: firstPoint))
                    lastTap = nil
                } else {
                    lastTap = (time, firstPoint)
                }
            } else if mode == .candidate && enabled && !panMode &&
                maxDistance <= (direct ? Self.directSlop : Self.trackpadSlop) && time - startTime <= 0.55 {
                let clickCount = secondTap ? 2 : 1
                let accepted = onCommand(.click(count: clickCount))
                lastTap = accepted && clickCount == 1 ? (time, direct ? directPoint : firstPoint) : nil
            } else if mode == .drag || mode == .precision {
                finishContinuous(cancelled: false)
                lastTap = nil
            } else {
                lastTap = nil
            }
            resetSequence()
            active = next
            return
        }
        if let point = next.values.first { processOne(point, at: time) }
        active = next
    }

    /// Needed for a stationary second-tap hold (and a direct touch-and-hold); timestamps use
    /// UITouch/system uptime.
    func tick(at time: TimeInterval) {
        guard time.isFinite else { return }
        if let id = momentumStream { stepMomentum(id, at: time) }
        if active.count == 2, mode == .multiCandidate, !panMode {
            // A deliberate anchored pinch can settle while both contacts are held still.
            processMulti(active, at: time)
            return
        }
        if mode == .scroll, let id = scrollID, enabled, !panMode,
           time - lastScrollSent >= Self.scrollKeepAliveInterval {
            // Resting fingers send nothing, but the Mac retires a silent scroll after 0.5 s.
            lastScrollSent = time
            _ = onCommand(.scroll(delta: .zero, phase: "changed", stream: id))
            return
        }
        guard active.count == 1, mode == .candidate, enabled, !panMode else { return }
        if secondTap {
            guard time - startTime >= 0.22 else { return }
            beginDrag(count: 2)
        } else if direct, precision != .off, !precisionDeclined, time - startTime >= Self.precisionHoldDelay {
            beginPrecision(at: active.values.first ?? firstPoint)
            if mode != .precision { precisionDeclined = true }
        } else if direct, time - startTime >= Self.directHoldDelay {
            beginDrag(count: 1)
        }
    }

    func cancel() {
        stopMomentum()
        cancelOwnedCommand()
        lastTap = nil
        if !active.isEmpty { mode = .blocked }
    }

    private func processOne(_ point: CGPoint, at time: TimeInterval) {
        maxDistance = max(maxDistance, distance(point, firstPoint))
        switch mode {
        case .candidate where direct && enabled:
            // A deliberate slide presses the button where the touch landed, then follows it.
            guard maxDistance > Self.directSlop else { return }
            beginDrag(count: secondTap ? 2 : 1)
            if mode == .drag { pointDirectly(at: point) }
        case .candidate:
            guard maxDistance > Self.trackpadSlop else {
                lastPoint = point
                lastMotionTime = time
                return
            }
            if secondTap {
                if time - startTime >= 0.07 { beginDrag(count: 2) }
                if mode == .drag {
                    discardLandingMotion(toward: point, at: time)
                    sendMotion(point, at: time)
                } else {
                    lastPoint = point
                    lastMotionTime = time
                }
            } else {
                mode = .pointer
                lastTap = nil
                discardLandingMotion(toward: point, at: time)
                sendMotion(point, at: time)
            }
        case .drag where direct:
            pointDirectly(at: point)
        case .precision:
            guard point != lastPoint else { return }
            lastPoint = point
            _ = onCommand(.precision(.moved, point))
        case .pointer, .drag:
            sendMotion(point, at: time)
        case .pan:
            if maxDistance > 4 {
                lastTap = nil
                let delta = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
                if delta != .zero { _ = onCommand(.pan(delta)) }
                lastPoint = point
            }
        default: break
        }
    }

    private func beginPrecision(at point: CGPoint) {
        guard onCommand(.precision(.began, point)) else { return }
        precisionActive = true
        mode = .precision
        lastPoint = point
        lastTap = nil
    }

    private func beginDrag(count: Int) {
        let id = UUID().uuidString
        if onCommand(.dragBegan(id: id, count: count)) {
            dragID = id
            mode = .drag
            lastTap = nil
        } else {
            mode = .blocked
        }
    }

    /// Start at the segment's exit from the tap radius. Interpolate its timestamp too so
    /// the gain sees the finger's velocity, independent of callback frequency.
    private func discardLandingMotion(toward point: CGPoint, at time: TimeInterval) {
        guard distance(lastPoint, firstPoint) < Self.trackpadSlop else { return }
        let dx = point.x - lastPoint.x, dy = point.y - lastPoint.y
        let ox = lastPoint.x - firstPoint.x, oy = lastPoint.y - firstPoint.y
        let a = dx * dx + dy * dy
        guard a > 0 else { return }
        let b = 2 * (ox * dx + oy * dy)
        let c = ox * ox + oy * oy - Self.trackpadSlop * Self.trackpadSlop
        let fraction = min(1, max(0, (-b + sqrt(max(0, b * b - 4 * a * c))) / (2 * a)))
        lastPoint.x += dx * fraction
        lastPoint.y += dy * fraction
        lastMotionTime += (time - lastMotionTime) * Double(fraction)
    }

    /// Absolute motion needs no gain or residual: the pointer is wherever the finger is.
    private func pointDirectly(at point: CGPoint) {
        guard enabled, point != lastPoint else { return }
        lastPoint = point
        _ = onCommand(.pointTo(point))
    }

    private func sendMotion(_ point: CGPoint, at time: TimeInterval) {
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        let dt = max(1.0 / 240.0, min(0.1, time - lastMotionTime))
        lastPoint = point
        lastMotionTime = time
        guard enabled, dx.isFinite, dy.isFinite else { return }
        let speed = hypot(dx, dy) / dt
        // Continuous bounded curve. A constant physical speed yields the same
        // total travel at different callback rates; no smoothing or inertia.
        let t = min(1, max(0, (speed - 35) / 900))
        let gain = gestureSensitivity * (0.55 + 1.95 * t * t * (3 - 2 * t)) / gestureScale
        let x = dx * gain + residual.width
        let y = dy * gain + residual.height
        let unit: CGFloat = 64
        let sentX = (x * unit).rounded(.towardZero) / unit
        let sentY = (y * unit).rounded(.towardZero) / unit
        residual = CGSize(width: x - sentX, height: y - sentY)
        if sentX != 0 || sentY != 0 {
            let accepted = onCommand(.move(CGSize(width: sentX, height: sentY)))
            if accepted && mode == .pointer { pointerMotionActive = true }
        }
    }

    private func beginMulti(_ touches: [UInt64: CGPoint]) {
        let points = Array(touches.values)
        guard points.count == 2 else { mode = .blocked; return }
        multiStartCenter = midpoint(points[0], points[1])
        multiOrigins = touches
        multiStartTime = lastUpdateTime
        multiLastCenter = multiStartCenter
        multiStartDistance = distance(points[0], points[1])
        multiLastDistance = multiStartDistance
        maxDistance = 0
        mode = .multiCandidate
    }

    private func processMulti(_ touches: [UInt64: CGPoint], at time: TimeInterval) {
        let points = Array(touches.values)
        let center = midpoint(points[0], points[1])
        let span = distance(points[0], points[1])
        let travel = distance(center, multiStartCenter)
        let scaleChange = abs(log(max(span, 1) / max(multiStartDistance, 1)))
        maxDistance = max(maxDistance, travel, abs(span - multiStartDistance))
        if panMode {
            // View navigation owns both translation and scale, so moving the fingers
            // together can become a pinch without lifting or leaking a Mac scroll.
            let starting = mode == .multiCandidate
            guard mode == .zoom || (starting && (travel >= 5 ||
                (scaleChange >= 0.055 && abs(span - multiStartDistance) >= 5))) else { return }
            let previousCenter = starting ? multiStartCenter : multiLastCenter
            let previousSpan = starting ? multiStartDistance : multiLastDistance
            mode = .zoom
            let factor = span / max(previousSpan, 1)
            if factor.isFinite && factor > 0 {
                if abs(factor - 1) > 0.001 { zoomActive = true }
                _ = onCommand(.navigate(factor: factor, anchor: previousCenter,
                    translation: CGSize(width: center.x - previousCenter.x,
                                        height: center.y - previousCenter.y)))
            }
            multiLastCenter = center
            multiLastDistance = span
            return
        }
        var justRecognizedZoom = false
        if mode == .multiCandidate {
            // Span alone confuses unequal parallel motion with pinch, especially for close
            // fingers. Compare each contact with its own origin instead of its array order.
            let motion = touches.compactMap { id, point -> CGSize? in
                guard let origin = multiOrigins[id] else { return nil }
                return CGSize(width: point.x - origin.x, height: point.y - origin.y)
            }
            guard motion.count == 2 else { mode = .blocked; return }
            let lengths = motion.map { hypot($0.width, $0.height) }
            let dot = motion[0].width * motion[1].width + motion[0].height * motion[1].height
            let product = lengths[0] * lengths[1]
            let bothMoving = min(lengths[0], lengths[1]) >= Self.multiFingerMotionSlop
            // A small but aligned partner movement is evidence of scrolling too. Do not
            // reinterpret a paused (+12,+1) parallel lead as an anchored pinch on a tick.
            let together = min(lengths[0], lengths[1]) >= Self.multiFingerMotionSlop * 0.5 &&
                dot >= product * 0.5
            let opposing = bothMoving && dot <= -product * 0.25
            let spanChange = abs(span - multiStartDistance)
            let anchored = min(lengths[0], lengths[1]) < Self.multiFingerMotionSlop &&
                max(lengths[0], lengths[1]) >= 12 && spanChange >= 8 &&
                spanChange >= max(lengths[0], lengths[1]) * 0.7 &&
                time - multiStartTime >= Self.anchoredPinchDelay
            let zooms = !together && scaleChange >= 0.055 && spanChange >= 5 && (opposing || anchored)
            let scrolls = !zooms && travel >= 5 && (together || spanChange < travel * 0.75)
            if zooms {
                mode = .zoom
                zoomActive = true
                justRecognizedZoom = true
            } else if scrolls {
                if panMode {
                    mode = .pan
                    _ = onCommand(.pan(CGSize(width: center.x - multiStartCenter.x,
                                               height: center.y - multiStartCenter.y)))
                } else {
                    mode = .scroll
                }
                if enabled && !panMode {
                    // Direct touch scrolls what is under the fingers. The pointer stays put for
                    // the rest of the scroll so the Mac keeps one scroll target.
                    if direct { _ = onCommand(.pointTo(multiStartCenter)) }
                    let id = UUID().uuidString
                    scrollID = id
                    sendScroll(CGSize(width: center.x - multiStartCenter.x,
                                      height: center.y - multiStartCenter.y), phase: "began", stream: id)
                }
            }
        } else if mode == .zoom {
            let factor = span / max(multiLastDistance, 1)
            if factor.isFinite && factor > 0 {
                _ = onCommand(.navigate(factor: factor, anchor: multiLastCenter,
                    translation: CGSize(width: center.x - multiLastCenter.x,
                                        height: center.y - multiLastCenter.y)))
            }
        } else if mode == .scroll, let id = scrollID, enabled {
            let delta = CGSize(width: center.x - multiLastCenter.x,
                               height: center.y - multiLastCenter.y)
            if delta != .zero { sendScroll(delta, phase: "changed", stream: id) }
        } else if mode == .pan && panMode {
            let delta = CGSize(width: center.x - multiLastCenter.x,
                               height: center.y - multiLastCenter.y)
            if delta != .zero { _ = onCommand(.pan(delta)) }
        }
        // The first recognition sample is included in its selected mode.
        if justRecognizedZoom {
            let factor = span / max(multiStartDistance, 1)
            // Include all pre-recognition motion, keeping the original source point under
            // the moving midpoint just as View navigation does. Pinch owns no Mac input.
            if factor.isFinite && factor > 0 {
                _ = onCommand(.navigate(factor: factor, anchor: multiStartCenter,
                    translation: CGSize(width: center.x - multiStartCenter.x,
                                        height: center.y - multiStartCenter.y)))
            }
        }
        multiLastCenter = center
        multiLastDistance = span
    }

    /// Scroll in Mac points, so the content under the fingers moves as far as the fingers do
    /// at any zoom, the way pointer motion is already scaled.
    private func sendScroll(_ delta: CGSize, phase: String, stream: String) {
        lastScrollSent = lastUpdateTime
        let scaled = CGSize(width: delta.width / gestureScale, height: delta.height / gestureScale)
        if phase == "began" { momentum.resetSamples() }
        momentum.record(scaled, at: lastUpdateTime)
        _ = onCommand(.scroll(delta: scaled, phase: phase, stream: stream))
    }

    /// After the fingers lift, continue the same stream with momentum phases until it coasts out.
    private func beginMomentum(stream: String) {
        guard momentumEnabled, enabled, !panMode else {
            momentum.resetSamples()
            return
        }
        if hostMomentumEnabled {
            defer { momentum.resetSamples() }
            guard let lift = momentum.liftVelocity(at: lastUpdateTime) else { return }
            guard onCommand(.scroll(delta: CGSize(width: lift.dx, height: lift.dy),
                                    phase: ScrollMomentumPhase.began.rawValue, stream: stream)) else { return }
            momentumStream = stream
            hostCoasting = true
            hostCoastUntil = lastUpdateTime + ScrollMomentum.maximumDuration + ScrollMomentum.hostCoastSlack
            return
        }
        guard momentum.start(at: lastUpdateTime) else {
            momentum.resetSamples()
            return
        }
        guard onCommand(.scroll(delta: .zero, phase: ScrollMomentumPhase.began.rawValue, stream: stream)) else {
            _ = momentum.cancel()
            return
        }
        momentumStream = stream
    }

    private func stepMomentum(_ stream: String, at time: TimeInterval) {
        guard !hostCoasting else { return }
        switch momentum.step(at: time) {
        case .changed(let delta)?:
            guard delta != .zero else { return }
            if !onCommand(.scroll(delta: delta, phase: ScrollMomentumPhase.changed.rawValue, stream: stream)) {
                stopMomentum()
            }
        case .ended?:
            momentumStream = nil
            _ = onCommand(.scroll(delta: .zero, phase: ScrollMomentumPhase.ended.rawValue, stream: stream))
        case nil:
            break
        }
    }

    private func stopMomentum() {
        let wasRunning = momentum.cancel()
        guard let id = momentumStream else { return }
        momentumStream = nil
        if hostCoasting {
            hostCoasting = false
            // The Mac may still be coasting: its end event follows this message at once.
            guard lastUpdateTime < hostCoastUntil else { return }
            _ = onCommand(.scroll(delta: .zero, phase: ScrollMomentumPhase.ended.rawValue, stream: id))
            return
        }
        if wasRunning { _ = onCommand(.scroll(delta: .zero, phase: ScrollMomentumPhase.ended.rawValue, stream: id)) }
    }

    private func beginWorkspace(_ touches: [UInt64: CGPoint], eligible: Bool) {
        workspaceSequence = true
        workspaceOrigins = touches
        workspaceTapEligible = eligible && touches.count == 3
        workspaceSwipeFired = false
        lastTap = nil
        hadTwo = true
        mode = eligible ? .workspaceCandidate : .blocked
    }

    private func trackWorkspaceTravel(_ touches: [UInt64: CGPoint]) {
        guard workspaceTapEligible else { return }
        for (id, point) in touches {
            guard let origin = workspaceOrigins[id] else { continue }
            if distance(point, origin) > Self.threeFingerTapTravel {
                workspaceTapEligible = false
                return
            }
        }
    }

    private func fireMiddleClick() {
        if direct {
            let points = Array(workspaceOrigins.values)
            guard !points.isEmpty else { return }
            let centroid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                   y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            guard onCommand(.pointTo(centroid)) else { return }
        }
        _ = onCommand(.middleClick)
    }

    private func processWorkspace(_ touches: [UInt64: CGPoint], at time: TimeInterval) {
        guard mode == .workspaceCandidate, enabled, !panMode else { return }
        guard time - startTime <= 1 else { mode = .blocked; return }
        let deltas = touches.compactMap { id, point -> CGSize? in
            guard let origin = workspaceOrigins[id] else { return nil }
            return CGSize(width: point.x - origin.x, height: point.y - origin.y)
        }
        guard deltas.count == 3 else { mode = .blocked; return }
        let dx = deltas.reduce(CGFloat.zero) { $0 + $1.width } / 3
        let dy = deltas.reduce(CGFloat.zero) { $0 + $1.height } / 3
        let horizontal = abs(dx) > abs(dy) * 1.4
        let vertical = abs(dy) > abs(dx) * 1.4
        let direction: NativeSwipeDirection
        if horizontal && abs(dx) >= 60 && deltas.allSatisfy({ $0.width * (dx > 0 ? 1 : -1) >= 20 }) {
            direction = dx > 0 ? .right : .left
        } else if vertical && abs(dy) >= 60 && deltas.allSatisfy({ $0.height * (dy > 0 ? 1 : -1) >= 20 }) {
            direction = dy > 0 ? .down : .up
        } else { return }
        mode = .workspaceFired
        workspaceSwipeFired = true
        workspaceTapEligible = false
        _ = onCommand(.workspaceSwipe(direction: direction))
    }

    private func endPointerMotion() {
        guard pointerMotionActive else { return }
        pointerMotionActive = false
        onPointerMotionEnded()
    }

    private func finishContinuous(cancelled: Bool) {
        endPointerMotion()
        if let id = scrollID {
            _ = onCommand(.scroll(delta: .zero, phase: cancelled ? "cancelled" : "ended", stream: id))
            scrollID = nil
            if cancelled { momentum.resetSamples() } else { beginMomentum(stream: id) }
        }
        if let id = dragID {
            _ = onCommand(.dragEnded(id: id))
            dragID = nil
        }
        if zoomActive {
            zoomActive = false
            _ = onCommand(.zoomEnded)
        }
        if precisionActive {
            precisionActive = false
            _ = onCommand(.precision(cancelled ? .cancelled : .ended, lastPoint))
        }
    }

    private func cancelOwnedCommand() { finishContinuous(cancelled: true) }

    private func resetSequence() {
        endPointerMotion()
        mode = .blocked
        workspaceSequence = false
        workspaceOrigins = [:]
        workspaceTapEligible = false
        workspaceSwipeFired = false
        hadTwo = false
        multiTapEligible = false
        multiOrigins = [:]
        secondTap = false
        residual = .zero
    }

    private static func safeSensitivity(_ x: CGFloat) -> CGFloat { x.isFinite ? min(2, max(0.5, x)) : 1 }
    private static func safeScale(_ x: CGFloat) -> CGFloat { x.isFinite ? min(8, max(0.05, x)) : 1 }
    private static func safeInterval(_ x: TimeInterval) -> TimeInterval { x.isFinite ? min(2, max(0.1, x)) : 0.5 }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}
