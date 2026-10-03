import AppKit
import ScreenCaptureKit

struct RemoteInputOutcome: Equatable {
    enum HoldEvent: Equatable {
        case none
        case began
        case refreshed
        case ended
    }

    var accepted = false
    var holdEvent: HoldEvent = .none
    var textRequestID: String?
    /// Exact position used for an accepted click, before later pointer movement can change it.
    var clickPoint: CGPoint?
}

struct RemoteInputLease {
    private(set) var duration: TimeInterval
    private(set) var deadline: TimeInterval?

    init(duration: TimeInterval = 2) {
        self.duration = duration
    }

    /// An armed deadline means a failed release is still being retried, so a new duration may only shorten it.
    mutating func changeDuration(to duration: TimeInterval, at time: TimeInterval) {
        self.duration = duration
        if let deadline { self.deadline = min(deadline, time + duration) }
    }

    mutating func begin(at time: TimeInterval) {
        deadline = time + duration
    }

    mutating func refreshFromMove(at time: TimeInterval) {
        guard deadline != nil else { return }
        deadline = time + duration
    }

    mutating func record(action: String, accepted: Bool, at time: TimeInterval) {
        guard accepted else { return }
        if action == "dragDown" { begin(at: time) }
        else if action == "move" || action == "moveTo" || action == "holdRenew" { refreshFromMove(at: time) }
    }

    mutating func cancel() {
        deadline = nil
    }

    func isExpired(at time: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return time >= deadline
    }
}

struct RemoteInputEpoch {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func beginSession() -> UInt64 {
        value &+= 1
        if value == 0 { value = 1 }
        return value
    }

    func accepts(_ action: RemoteAction) -> Bool {
        action.action == "release" || action.action == "heartbeat" || action.epoch == value
    }
}

/// Marks every event the phone injects, so Mac-side listeners (the privacy curtain's local
/// Escape shortcut) can tell them apart from the physical keyboard.
enum RemoteInputTag {
    static let value: Int64 = 0x4641_5253_4944_4531

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func isInjected(_ event: CGEvent?, ownPID: pid_t = getpid()) -> Bool {
        guard let event else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == value
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ownPID)
    }
}

struct RemoteInputEventSink {
    struct MouseEvent {
        var type: CGEventType
        var point: CGPoint
        var button: CGMouseButton
        var count: Int64
        /// Modifier keys held on the phone's hardware keyboard (⌘-click, ⇧-click, ⌥-drag).
        var flags: CGEventFlags = []
        var pencil: PencilFrame? = nil
        /// How far the pointer moved since the last posted pointer event; zero for buttons.
        var delta: CGSize = .zero
    }

    /// Host user default; absent means on. `defaults write com.roshan.PocketDesk.RemoteHost input.eventDeltas -bool NO`
    /// posts moves and drags without `mouseEventDeltaX/Y`, as before the feel pass.
    static let deltaFieldsKey = "input.eventDeltas"
    static let deltaFieldsEnabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: deltaFieldsKey) == nil || defaults.bool(forKey: deltaFieldsKey)
    }()

    var pointerLocation: () -> CGPoint
    var mouseSequence: ([MouseEvent]) -> Bool
    var scroll: (CGPoint, Double, Double) -> Bool
    var scrollDetailed: ((CGPoint, Double, Double, String) -> Bool)? = nil
    /// Optional extensions preserve existing injected sink call sites and baseline callbacks.
    var scrollWithFlags: ((CGPoint, Double, Double, CGEventFlags) -> Bool)? = nil
    var scrollDetailedWithFlags: ((CGPoint, Double, Double, String, CGEventFlags) -> Bool)? = nil
    var text: ([UniChar]) -> Bool
    var key: (CGKeyCode, CGEventFlags) -> Bool

    static func makeMouseEvent(_ description: MouseEvent, deltas: Bool = deltaFieldsEnabled) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: RemoteInputEventSource.shared,
            mouseType: description.type, mouseCursorPosition: description.point, mouseButton: description.button) else { return nil }
        event.setIntegerValueField(.mouseEventClickState, value: description.count)
        if deltas {
            // A real mouse reports its motion here; pointer-lock games, 3D viewports and some drag
            // handlers read it instead of the absolute location.
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(description.delta.width.rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(description.delta.height.rounded()))
        }
        if !description.flags.isEmpty { event.flags = description.flags }
        if let pen = description.pencil {
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setDoubleValueField(.mouseEventPressure, value: pen.pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pen.pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: pen.tiltX)
            event.setDoubleValueField(.tabletEventTiltY, value: pen.tiltY)
            event.setIntegerValueField(.tabletEventPointButtons, value: pen.phase == .hover || pen.phase == .ended || pen.phase == .cancelled ? 0 : 1)
            // No invented system tablet/device identity or private driver interface.
        }
        return event
    }

    /// Creates the exact scroll event used by the live sink without posting it. Nil flags preserve
    /// baseline source semantics; an explicit empty mask clears modifiers for the upgraded path.
    static func makeScrollEvent(point: CGPoint, horizontal: Double, vertical: Double,
                                phase: String? = nil, flags: CGEventFlags? = nil) -> CGEvent? {
        let clampedX = min(2000, max(-2000, horizontal))
        let clampedY = min(2000, max(-2000, vertical))
        guard let event = CGEvent(scrollWheelEvent2Source: RemoteInputEventSource.shared,
            units: .pixel, wheelCount: 2, wheel1: Int32(clampedY.rounded(.towardZero)),
            wheel2: Int32(clampedX.rounded(.towardZero)), wheel3: 0) else { return nil }
        event.location = point
        if let phase {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64((clampedY * 65_536).rounded()))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64((clampedX * 65_536).rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(clampedY.rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(clampedX.rounded()))
            let phases = ScrollEventPhases.values(for: phase)
            if phases.scroll != 0 { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.scroll) }
            if phases.momentum != 0 { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.momentum) }
        }
        if let flags { event.flags = event.flags.intersection(.maskNonCoalesced).union(flags) }
        RemoteInputTag.mark(event)
        return event
    }

    /// Construct the existing atomic press/release pair; tests inspect it without posting input.
    static func makeKeyEvents(key: CGKeyCode, flags: CGEventFlags) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: RemoteInputEventSource.shared, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: RemoteInputEventSource.shared, virtualKey: key, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = flags
            RemoteInputTag.mark(event)
        }
        return [down, up]
    }

    static let live = RemoteInputEventSink(
        pointerLocation: { CGEvent(source: nil)?.location ?? .zero },
        mouseSequence: { descriptions in
            var events: [CGEvent] = []
            for description in descriptions {
                guard let event = makeMouseEvent(description) else { return false }
                events.append(event)
            }
            for event in events { RemoteInputTag.mark(event); event.post(tap: .cghidEventTap) }
            return true
        },
        scroll: { point, horizontal, vertical in
            guard let event = makeScrollEvent(point: point, horizontal: horizontal, vertical: vertical) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        },
        scrollDetailed: { point, horizontal, vertical, phase in
            guard let event = makeScrollEvent(point: point, horizontal: horizontal, vertical: vertical, phase: phase) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        },
        scrollWithFlags: { point, horizontal, vertical, flags in
            guard let event = makeScrollEvent(point: point, horizontal: horizontal, vertical: vertical, flags: flags) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        },
        scrollDetailedWithFlags: { point, horizontal, vertical, phase, flags in
            guard let event = makeScrollEvent(point: point, horizontal: horizontal, vertical: vertical, phase: phase, flags: flags) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        },
        text: { characters in
            guard let down = CGEvent(keyboardEventSource: RemoteInputEventSource.shared, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: RemoteInputEventSource.shared, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                characters.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress)
                }
                RemoteInputTag.mark(event)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        },
        key: { key, flags in
            guard let events = makeKeyEvents(key: key, flags: flags) else { return false }
            for event in events { event.post(tap: .cghidEventTap) }
            return true
        }
    )
}

final class RemoteInputDriver {
    var enabled = false
    var displayBounds: CGRect?
    var windowID: CGWindowID?
    var report: ((String) -> Void)?

    private(set) var held = false
    private(set) var holdID: UInt64?
    private(set) var externalHoldID: String?
    private var nextHoldID: UInt64 = 0
    private var retiredHolds: Set<String> = []
    private var retiredHoldOrder: [String] = []
    private var heldClickCount: Int64 = 1
    private var lastClick = 0.0
    private var clicks: Int64 = 0
    private(set) var lastPoint = CGPoint.zero
    /// Phone pointer events arrive at up to 120 Hz while WindowServer applies posted events
    /// asynchronously, later than the next event on a loaded Mac. Reading the cursor back as
    /// the base for a relative move then drops motion, and a click posted at a stale read moves
    /// the cursor back to it. While pointer events are streaming and the cursor still reads as
    /// one of the points recently posted (it is lagging, not moved by a physical mouse), the
    /// base is the last point this driver posted.
    static let pointerChainWindow: TimeInterval = 0.2
    static let pointerChainTolerance: CGFloat = 1
    private static let recentPostLimit = 64
    private var lastPostedAt: TimeInterval = -.infinity
    private var recentPosts: [CGPoint] = []
    private var lastButton: CGMouseButton?
    private var lastSemanticPoint: CGPoint?
    private var activeScroll: String?
    private var retiredScrolls: Set<String> = []
    private var retiredScrollOrder: [String] = []
    private var scrollDeadline: TimeInterval = 0
    /// Only accepted scroll events may replace these; generated momentum never adopts new wire flags.
    private var scrollFlags: CGEventFlags = []
    private var scrollFlagsStream: String?
    private var momentumFlags: CGEventFlags = []
    var scrollModifiers = ScrollModifierPolicy.hostProcessEnabled
    private(set) var momentum = ScrollMomentumGate()
    /// Host user default; absent means on. `defaults write com.roshan.PocketDesk.RemoteHost input.hostMomentum -bool NO`
    /// stops advertising `SessionFeature.hostMomentum`, so the phone paces the coast itself as before.
    static let hostMomentumKey = "input.hostMomentum"
    static let hostMomentumEnabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: hostMomentumKey) == nil || defaults.bool(forKey: hostMomentumKey)
    }()
    /// The coast the Mac runs itself from the phone's lift velocity (`SessionFeature.hostMomentum`).
    /// It is stepped from the executor's timer, never from a network message, so it runs at the
    /// rate of a real trackpad whatever the link is doing.
    static let hostMomentumInterval: TimeInterval = 1.0 / 120
    var hostMomentum = RemoteInputDriver.hostMomentumEnabled
    /// Same switch as `RemoteInputEventSink.deltaFieldsKey`: off restores the pre-feel-pass events exactly.
    var eventDeltas = RemoteInputEventSink.deltaFieldsEnabled
    private var coast = ScrollMomentum()
    var isCoasting: Bool { coast.isRunning }
    private let eventSink: RemoteInputEventSink
    private var activePencil: PencilFrame?
    private let isTrusted: () -> Bool

    init(
        eventSink: RemoteInputEventSink = .live,
        isTrusted: @escaping () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        self.eventSink = eventSink
        self.isTrusted = isTrusted
    }

    func configure(_ filter: SCContentFilter) {
        release()
        resetNativeSequence()
        displayRects = []
        if filter.style == .display {
            displayBounds = filter.includedDisplays.first?.frame
            windowID = nil
        } else {
            displayBounds = nil
            windowID = filter.includedWindows.first?.windowID
        }
    }

    func configure(bounds: CGRect?) {
        release()
        resetNativeSequence()
        displayRects = []
        displayBounds = bounds
        windowID = nil
    }

    /// Couch mode only: every display the pointer may use. Empty for Picture, which clamps to `displayBounds`.
    private(set) var displayRects: [CGRect] = []

    func configure(displays: [CGRect]) {
        release()
        resetNativeSequence()
        let usable = displays.filter {
            $0.width > 0 && $0.height > 0 && [$0.origin.x, $0.origin.y, $0.width, $0.height].allSatisfy(\.isFinite)
        }
        displayRects = usable
        displayBounds = usable.dropFirst().reduce(usable.first) { $0?.union($1) }
        windowID = nil
    }

    static func clamp(_ point: CGPoint, toNearestOf rects: [CGRect]) -> CGPoint {
        guard let first = rects.first else { return point }
        guard point.x.isFinite, point.y.isFinite else { return CGPoint(x: first.midX, y: first.midY) }
        var best = point
        var bestDistance = CGFloat.infinity
        for rect in rects {
            let candidate = CGPoint(x: min(rect.maxX.nextDown, max(rect.minX, point.x)),
                                    y: min(rect.maxY.nextDown, max(rect.minY, point.y)))
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }
        return best
    }

    func handle(_ input: RemoteAction, upgraded: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime, pointerSnapshot: CGPoint? = nil) -> RemoteInputOutcome {
        let requestID = input.action == "text" ? input.key : nil
        if let pen = input.pencil {
            guard upgraded, (try? pen.validate(action: input.action, interaction: input.interaction)) != nil else { return RemoteInputOutcome(textRequestID: requestID) }
            if pen.phase == .hover { guard !held else { return RemoteInputOutcome() } }
            else if pen.phase != .began { guard held, activePencil?.stream == pen.stream else { return RemoteInputOutcome() } }
        }
        if activePencil != nil && ["move", "moveTo", "dragUp"].contains(input.action) && input.pencil == nil { return RemoteInputOutcome() }
        if input.action != "holdRenew", !Self.isMomentum(input) { endMomentum() }
        if input.action == "release" {
            let hadHold = held
            let released = release()
            return RemoteInputOutcome(
                accepted: !hadHold || released,
                holdEvent: !hadHold || released ? .ended : .none,
                textRequestID: requestID
            )
        }
        guard enabled, isTrusted(), input.x.isFinite, input.y.isFinite else {
            return RemoteInputOutcome(textRequestID: requestID)
        }
        if upgraded, input.action != "scroll", let activeScroll {
            retireScroll(activeScroll)
            self.activeScroll = nil
        }

        var outcome = RemoteInputOutcome(textRequestID: requestID)
        let flags = Self.flags(for: input.modifiers)
        // A synchronous safety check may have already resolved this event's pointer base.
        // Reuse that exact point: WindowServer can advance between the check and injection.
        var resolvedPoint: CGPoint?
        func eventPoint(in bounds: CGRect) -> CGPoint {
            if let resolvedPoint { return resolvedPoint }
            let point: CGPoint
            if let pointerSnapshot {
                point = clamped(pointerSnapshot, to: bounds)
                remember(point)
            } else {
                point = pointerBase(now: now, in: bounds)
            }
            resolvedPoint = point
            return point
        }
        switch input.action {
        case "move", "moveTo":
            if upgraded && held && (input.interaction?.hold != externalHoldID || input.interaction?.clickCount != Int(heldClickCount)) { break }
            guard let bounds = validBounds else { break }
            let target: CGPoint
            let current: CGPoint
            if input.action == "moveTo" {
                // Display-local logical points, exactly as `geometry` described the display.
                guard input.x >= 0, input.y >= 0 else { break }
                target = CGPoint(x: bounds.minX + input.x, y: bounds.minY + input.y)
                // An absolute placement needs the base only for its delta, so it reads without recording.
                current = eventDeltas ? (pointerSnapshot.map { clamped($0, to: bounds) } ?? resolvedBase(now: now, in: bounds).point) : target
            } else {
                current = eventPoint(in: bounds)
                target = CGPoint(x: current.x + input.x, y: current.y + input.y)
            }
            let point = clamped(target, to: bounds)
            let wasHeld = held
            // A moving mouse has no click state; a drag carries the press that started it.
            let event = RemoteInputEventSink.MouseEvent(
                type: wasHeld ? .leftMouseDragged : .mouseMoved,
                point: point,
                button: .left,
                count: wasHeld ? heldClickCount : (eventDeltas ? 0 : 1),
                flags: flags, pencil: input.pencil,
                delta: eventDeltas ? CGSize(width: point.x - current.x, height: point.y - current.y) : .zero
            )
            guard eventSink.mouseSequence([event]) else { break }
            if input.pencil?.phase == .moved { activePencil = input.pencil }
            notePosted(point, at: now)
            if !wasHeld, let semanticPoint = lastSemanticPoint,
               hypot(point.x - semanticPoint.x, point.y - semanticPoint.y) > 5 { resetClickSequence() }
            outcome.accepted = true
            outcome.holdEvent = wasHeld ? .refreshed : .none

        case "middle":
            guard !held, let bounds = validBounds else { break }
            if upgraded { guard input.interaction?.clickCount == 1 else { break } }
            let point = eventPoint(in: bounds)
            let events: [RemoteInputEventSink.MouseEvent] = [
                .init(type: .otherMouseDown, point: point, button: .center, count: 1, flags: flags),
                .init(type: .otherMouseUp, point: point, button: .center, count: 1, flags: flags)
            ]
            guard eventSink.mouseSequence(events) else { break }
            notePosted(point, at: now)
            resetClickSequence()
            outcome.accepted = true
            outcome.clickPoint = point

        case "auxClick":
            guard !held, let bounds = validBounds, let button = RemoteMouseButton.auxiliary(input.key) else { break }
            if upgraded { guard input.interaction?.clickCount == 1 else { break } }
            let point = eventPoint(in: bounds)
            let events: [RemoteInputEventSink.MouseEvent] = [
                .init(type: button.downType, point: point, button: button.cgButton, count: 1, flags: flags),
                .init(type: button.upType, point: point, button: button.cgButton, count: 1, flags: flags)
            ]
            guard eventSink.mouseSequence(events) else { break }
            notePosted(point, at: now)
            resetClickSequence()
            outcome.accepted = true
            outcome.clickPoint = point

        case "click", "right", "double":
            guard !held, let bounds = validBounds else { break }
            let point = eventPoint(in: bounds)
            let right = input.action == "right"
            let button: CGMouseButton = right ? .right : .left
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let repetitions = input.action == "double" ? 2 : 1
            var events: [RemoteInputEventSink.MouseEvent] = []
            lastPoint = point
            if upgraded {
                // A multi-click continues only the click just before it: same button, same place.
                guard let count = input.interaction?.clickCount,
                      (1...3).contains(count),
                      (count == 1 || (clicks == Int64(count - 1) && lastButton == button &&
                        lastSemanticPoint.map { hypot($0.x - point.x, $0.y - point.y) <= 5 } == true)),
                      (!right || count == 1),
                      (input.action != "double" || count == 1)
                else { break }
                for index in 0..<repetitions {
                    let eventCount = Int64(count + index)
                    events.append(.init(type: down, point: point, button: button, count: eventCount, flags: flags))
                    events.append(.init(type: up, point: point, button: button, count: eventCount, flags: flags))
                }
                guard eventSink.mouseSequence(events) else { break }
                clicks = Int64(count + repetitions - 1)
                lastButton = button
                lastSemanticPoint = point
                outcome.accepted = true
                outcome.clickPoint = point
                break
            }
            for index in 0..<repetitions {
                let now = CACurrentMediaTime()
                clicks = now - lastClick < NSEvent.doubleClickInterval ? min(clicks + 1, 3) : 1
                if repetitions == 2 { clicks = Int64(index + 1) }
                lastClick = now
                events.append(.init(type: down, point: point, button: button, count: clicks, flags: flags))
                events.append(.init(type: up, point: point, button: button, count: clicks, flags: flags))
            }
            outcome.accepted = eventSink.mouseSequence(events)
            if outcome.accepted {
                outcome.clickPoint = point
                notePosted(point, at: now)
            }

        case "dragDown":
            guard !held, let bounds = validBounds else { break }
            if upgraded {
                guard let identity = input.interaction?.hold,
                      !identity.isEmpty, !retiredHolds.contains(identity),
                      let count = input.interaction?.clickCount, count == 1 || count == 2
                else { break }
                let point = eventPoint(in: bounds)
                guard count == 1 || (clicks == 1 && lastButton == .left &&
                    lastSemanticPoint.map { hypot($0.x - point.x, $0.y - point.y) <= 5 } == true)
                else { break }
            }
            let point = eventPoint(in: bounds)
            let count = upgraded ? Int64(input.interaction!.clickCount!) : 1
            let event = RemoteInputEventSink.MouseEvent(type: .leftMouseDown, point: point, button: .left,
                                                        count: count, flags: flags, pencil: input.pencil)
            guard eventSink.mouseSequence([event]) else { break }
            activePencil = input.pencil
            notePosted(point, at: now)
            held = true
            heldClickCount = count
            externalHoldID = upgraded ? input.interaction?.hold : nil
            if let externalHoldID { retireHold(externalHoldID) }
            nextHoldID &+= 1
            if nextHoldID == 0 { nextHoldID = 1 }
            holdID = nextHoldID
            outcome.accepted = true
            outcome.holdEvent = .began

        case "dragUp":
            if upgraded && (input.interaction?.hold != externalHoldID || input.interaction?.clickCount != Int(heldClickCount)) { break }
            let wasHeld = held
            outcome.accepted = release()
            outcome.holdEvent = wasHeld && outcome.accepted ? .ended : .none

        case "holdRenew":
            guard upgraded, held, input.interaction?.hold == externalHoldID,
                  input.interaction?.clickCount == Int(heldClickCount) else { break }
            outcome.accepted = true
            outcome.holdEvent = .refreshed

        case "scroll":
            guard let bounds = validBounds else { break }
            var dx = input.x, dy = input.y
            var eventFlags = flags
            var acceptedGestureFlags: CGEventFlags?
            var acceptedMomentumFlags: CGEventFlags?
            if upgraded {
                guard let stream = input.interaction?.stream,
                      let phase = input.interaction?.phase else { break }
                if let momentumPhase = ScrollMomentumPhase(rawValue: phase) {
                    guard momentum.admit(momentumPhase, stream: stream, at: now) == .post else { break }
                    eventFlags = momentumPhase == .began ? (scrollFlagsStream == stream ? scrollFlags : []) : momentumFlags
                    if momentumPhase == .began { acceptedMomentumFlags = eventFlags }
                    if momentumPhase == .began, hostMomentum, dx != 0 || dy != 0 {
                        // The phone sent its lift velocity: the Mac coasts from here, posting the
                        // begin event with no travel of its own.
                        dx = 0; dy = 0
                        guard coast.start(velocity: CGVector(dx: input.x, dy: input.y), at: now) else {
                            _ = momentum.interrupt()
                            break
                        }
                    } else if momentumPhase == .ended {
                        _ = coast.cancel()
                    }
                } else {
                    if let activeScroll, now >= scrollDeadline {
                        retireScroll(activeScroll)
                        self.activeScroll = nil
                    }
                    if phase == "began" {
                        guard activeScroll != stream, !retiredScrolls.contains(stream) else { break }
                        if let activeScroll { retireScroll(activeScroll) }
                        activeScroll = stream
                    } else {
                        guard activeScroll == stream, now < scrollDeadline else { break }
                    }
                    scrollDeadline = now + 0.5
                    if phase == "ended" || phase == "cancelled" {
                        eventFlags = scrollFlagsStream == stream ? scrollFlags : []
                        retireScroll(stream)
                        activeScroll = nil
                        if phase == "ended" { momentum.gestureEnded(stream: stream, at: now) }
                    } else if phase == "changed" && input.x == 0 && input.y == 0 {
                        // Fingers resting mid-scroll: keep the stream alive, post nothing.
                        outcome.accepted = true
                        scrollFlags = eventFlags
                        scrollFlagsStream = stream
                        break
                    } else {
                        acceptedGestureFlags = eventFlags
                    }
                }
            }
            let point = eventPoint(in: bounds)
            lastPoint = point
            outcome.accepted = postScroll(point, dx, dy, phase: upgraded ? input.interaction?.phase : nil, flags: eventFlags)
            if outcome.accepted {
                if let acceptedGestureFlags {
                    scrollFlags = acceptedGestureFlags
                    scrollFlagsStream = input.interaction?.stream
                }
                if let acceptedMomentumFlags { momentumFlags = acceptedMomentumFlags }
                if input.interaction?.phase == ScrollMomentumPhase.ended.rawValue { momentumFlags = [] }
                if input.interaction?.phase == "cancelled" { scrollFlags = []; scrollFlagsStream = nil }
            } else if coast.isRunning, scrollModifiers || (upgraded && eventSink.scrollDetailed != nil) {
                _ = coast.cancel(); _ = momentum.interrupt(); momentumFlags = []
            }

        case "text":
            guard !input.key.isEmpty, input.key.utf8.count <= 32,
                  input.text.utf8.count <= 4096, input.text.utf16.count <= 1024 else { break }
            outcome.accepted = eventSink.text(Array(input.text.utf16))
            if outcome.accepted { resetClickSequence() }

        case "key":
            guard let key = Self.keys[input.key] else { break }
            outcome.accepted = eventSink.key(key, flags.union(Self.intrinsicFlags(for: input.key)))
            if outcome.accepted { resetClickSequence() }

        default:
            break
        }
        if outcome.accepted { report?("Input accepted for injection: \(input.action)") }
        return outcome
    }

    static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    @discardableResult
    func release() -> Bool {
        guard held else { return false }
        let event = RemoteInputEventSink.MouseEvent(
            type: .leftMouseUp,
            point: lastPoint,
            button: .left,
            count: heldClickCount, pencil: activePencil?.zeroed()
        )
        guard eventSink.mouseSequence([event]) else { return false }
        held = false
        activePencil = nil
        holdID = nil
        externalHoldID = nil
        heldClickCount = 1
        resetClickSequence()
        return true
    }

    func resetNativeSequence() {
        endMomentum()
        resetClickSequence()
        // A new session or geometry starts from the real cursor, even when it replaces a
        // stream inside the short WindowServer settling window.
        lastPostedAt = -.infinity
        recentPosts.removeAll(keepingCapacity: true)
        externalHoldID = nil
        retiredHolds.removeAll()
        retiredHoldOrder.removeAll()
        activeScroll = nil
        retiredScrolls.removeAll()
        retiredScrollOrder.removeAll()
        scrollDeadline = 0
        scrollFlags = []
        scrollFlagsStream = nil
        momentumFlags = []
    }

    /// Ends a momentum the phone stopped sending, from the host's periodic timer.
    func expireMomentum(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if momentum.expire(at: now) { _ = coast.cancel(); postMomentumEnd() }
    }

    /// One step of the Mac-run coast. Returns false once there is nothing left to post, so the
    /// caller's timer can stop. Each step renews the gate, like a phone-sent `momentumChanged` would.
    @discardableResult
    func stepHostMomentum(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard coast.isRunning, let stream = momentum.active else { _ = coast.cancel(); return false }
        guard enabled, isTrusted() else { endMomentum(); return false }
        switch coast.step(at: now) {
        case .changed(let delta)?:
            guard momentum.admit(.changed, stream: stream, at: now) == .post else { _ = coast.cancel(); return false }
            guard delta != .zero else { return true }
            if !postScroll(lastPoint, delta.width, delta.height, phase: ScrollMomentumPhase.changed.rawValue, flags: momentumFlags, fallbackToUnphased: false) {
                _ = coast.cancel()
                _ = momentum.interrupt()
                momentumFlags = []
                return false
            }
            return true
        case .ended?:
            _ = momentum.admit(.ended, stream: stream, at: now)
            postMomentumEnd()
            return false
        case nil:
            return true
        }
    }

    /// Ends a Mac-run coast whose authority was revoked (control off, new generation, expired lease).
    func endHostMomentum() {
        guard coast.isRunning else { return }
        endMomentum()
    }

    /// Drops a Mac-run coast whose route is gone: nothing can be posted, so no end event either.
    func abandonHostMomentum() {
        guard coast.isRunning else { return }
        _ = coast.cancel()
        _ = momentum.interrupt()
        momentumFlags = []
    }

    private func endMomentum() {
        _ = coast.cancel()
        if momentum.interrupt() { postMomentumEnd() }
        momentumFlags = []
    }

    private func postMomentumEnd() {
        _ = postScroll(lastPoint, 0, 0, phase: ScrollMomentumPhase.ended.rawValue, flags: momentumFlags, fallbackToUnphased: false)
        momentumFlags = []
    }

    private func postScroll(_ point: CGPoint, _ horizontal: Double, _ vertical: Double,
                            phase: String?, flags: CGEventFlags, fallbackToUnphased: Bool = true) -> Bool {
        if let phase {
            if scrollModifiers, let detailed = eventSink.scrollDetailedWithFlags {
                return detailed(point, horizontal, vertical, phase, flags)
            }
            if let detailed = eventSink.scrollDetailed { return detailed(point, horizontal, vertical, phase) }
            guard fallbackToUnphased else { return false }
        }
        if scrollModifiers, let scroll = eventSink.scrollWithFlags { return scroll(point, horizontal, vertical, flags) }
        return eventSink.scroll(point, horizontal, vertical)
    }

    private static func isMomentum(_ input: RemoteAction) -> Bool {
        input.action == "scroll" && input.interaction?.phase.flatMap(ScrollMomentumPhase.init(rawValue:)) != nil
    }

    private func retireHold(_ identity: String) {
        guard retiredHolds.insert(identity).inserted else { return }
        retiredHoldOrder.append(identity)
        if retiredHoldOrder.count > 1024 {
            retiredHolds.remove(retiredHoldOrder.removeFirst())
        }
    }

    private func retireScroll(_ identity: String) {
        guard retiredScrolls.insert(identity).inserted else { return }
        retiredScrollOrder.append(identity)
        if retiredScrollOrder.count > 1024 {
            retiredScrolls.remove(retiredScrollOrder.removeFirst())
        }
    }

    private func resetClickSequence() {
        clicks = 0
        lastButton = nil
        lastSemanticPoint = nil
    }

    private var validBounds: CGRect? {
        if let displayBounds, displayBounds.width > 0, displayBounds.height > 0,
           displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
           displayBounds.width.isFinite, displayBounds.height.isFinite {
            return displayBounds
        }
        guard let windowID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = windows.first,
              let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Where the pointer is for the next event: the last point this driver posted while pointer
    /// events are streaming and the cursor still reads as a recently posted point, otherwise the
    /// cursor as WindowServer currently reports it.
    private func pointerBase(now: TimeInterval, in bounds: CGRect) -> CGPoint {
        let base = resolvedBase(now: now, in: bounds)
        if !base.chained { remember(base.point) }
        return base.point
    }

    private func resolvedBase(now: TimeInterval, in bounds: CGRect) -> (point: CGPoint, chained: Bool) {
        let observed = clamped(eventSink.pointerLocation(), to: bounds)
        if now >= lastPostedAt, now - lastPostedAt < Self.pointerChainWindow,
           recentPosts.contains(where: { hypot($0.x - observed.x, $0.y - observed.y) <= Self.pointerChainTolerance }) {
            return (clamped(lastPoint, to: bounds), true)
        }
        return (observed, false)
    }

    /// The point the next pointer event at `now` would start from, without recording anything.
    /// Pass the returned snapshot to `handle` after fencing; rereading the cursor can race WindowServer.
    func nextPointerBase(now: TimeInterval) -> CGPoint? {
        guard let bounds = validBounds else { return nil }
        return resolvedBase(now: now, in: bounds).point
    }

    /// Couch catch-up: preserve every relative segment's display-edge clamp, but emit only
    /// the final point. Drawing/Pencil paths and changes of modifiers or hold stay ordered.
    func coalescedCouchMotion(_ actions: [RemoteAction], now: TimeInterval) -> (action: RemoteAction, base: CGPoint)? {
        guard !displayRects.isEmpty, actions.count > 1, let first = actions.first,
              let bounds = validBounds else { return nil }
        var interaction = first.interaction; interaction?.token = nil
        guard actions.allSatisfy({ action in
            var candidate = action.interaction; candidate?.token = nil
            // Token rotation changes freshness, not motion semantics. The executor still
            // checks each original token's deadline and uses the earliest one for the post.
            return action.action == "move" && action.pencil == nil && action.x.isFinite && action.y.isFinite
                && action.modifiers == first.modifiers && candidate == interaction
        }) else { return nil }
        let base = resolvedBase(now: now, in: bounds).point
        var point = base
        var leftClickPoint = false
        for action in actions {
            point = clamped(CGPoint(x: point.x + action.x, y: point.y + action.y), to: bounds)
            if !held, let clickPoint = lastSemanticPoint, hypot(point.x - clickPoint.x, point.y - clickPoint.y) > 5 {
                leftClickPoint = true
            }
        }
        // An out-and-back excursion resets multi-click state even when the final point is
        // back beside the first click. Keep that path ordered instead of hiding the reset.
        if leftClickPoint, let clickPoint = lastSemanticPoint,
           hypot(point.x - clickPoint.x, point.y - clickPoint.y) <= 5 { return nil }
        var merged = actions.last!
        merged.x = point.x - base.x; merged.y = point.y - base.y
        return (merged, base)
    }

    /// A physical pointer intervention invalidates a causal anchor. Recently posted points
    /// may still be reported by WindowServer, so the existing chain window is respected.
    func pointerMatchesCausalAnchor(_ anchor: CGPoint?, now: TimeInterval) -> Bool {
        guard let bounds = validBounds, let anchor else { return false }
        let base = resolvedBase(now: now, in: bounds)
        return base.chained || hypot(base.point.x - anchor.x, base.point.y - anchor.y) <= Self.pointerChainTolerance
    }

    private func notePosted(_ point: CGPoint, at now: TimeInterval) {
        lastPoint = point
        lastPostedAt = now
        remember(point)
    }

    private func remember(_ point: CGPoint) {
        recentPosts.append(point)
        if recentPosts.count > Self.recentPostLimit { recentPosts.removeFirst(recentPosts.count - Self.recentPostLimit) }
    }

    private func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        if displayRects.count > 1 { return Self.clamp(point, toNearestOf: displayRects) }
        let fallback = CGPoint(x: bounds.midX, y: bounds.midY)
        let source = point.x.isFinite && point.y.isFinite ? point : fallback
        return CGPoint(
            x: min(bounds.maxX.nextDown, max(bounds.minX, source.x)),
            y: min(bounds.maxY.nextDown, max(bounds.minY, source.y))
        )
    }

    static let keys: [String: CGKeyCode] = legacyKeys.merging(extendedKeys) { old, _ in old }

    /// The original table; every phone may send these.
    static let legacyKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "tab": 48,
        "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
        "down": 125, "up": 126
    ]

    /// Hardware keyboards on the phone (`SessionFeature.extendedKeys`): positional virtual key codes.
    static let extendedKeys: [String: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "minus": 27, "equal": 24, "leftBracket": 33, "rightBracket": 30, "backslash": 42,
        "semicolon": 41, "quote": 39, "grave": 50, "comma": 43, "period": 47, "slash": 44, "section": 10,
        "forwardDelete": 117, "home": 115, "end": 119, "pageUp": 116, "pageDown": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86, "keypad5": 87,
        "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92, "keypadDecimal": 65,
        "keypadMultiply": 67, "keypadPlus": 69, "keypadClear": 71, "keypadDivide": 75,
        "keypadEnter": 76, "keypadMinus": 78, "keypadEquals": 81,
        "jisYen": 93, "jisUnderscore": 94, "jisKeypadComma": 95, "jisEisu": 102, "jisKana": 104
    ]

    /// Flags a Mac keyboard itself sets on these keys: Fn and numeric pad for arrows, Fn for
    /// function and navigation keys, numeric pad for the keypad. The system hotkeys for Mission
    /// Control and Spaces (⌃ plus an arrow) only match an arrow that carries Fn.
    static func intrinsicFlags(for key: String) -> CGEventFlags {
        if ["left", "right", "up", "down"].contains(key) { return [.maskSecondaryFn, .maskNumericPad] }
        if key.hasPrefix("keypad") { return .maskNumericPad }
        if ["forwardDelete", "home", "end", "pageUp", "pageDown", "help"].contains(key) { return .maskSecondaryFn }
        if key.count > 1, key.hasPrefix("f"), Int(key.dropFirst()) != nil { return .maskSecondaryFn }
        return []
    }
}
