import AppKit
import CoreGraphics

/// Where injected events come from. A private state table keeps the phone's modifiers apart from
/// the physical keyboard's: a Shift held at the Mac no longer lands on a phone click, and a phone
/// ⌘ never lingers in the session state. Every event from the source also carries
/// `RemoteInputTag.value`, so the curtain's local shortcut still tells them apart.
enum RemoteInputEventSource {
    /// Host user default; absent means on. `defaults write com.roshan.PocketDesk.RemoteHost input.privateEventSource -bool NO` reverts to the shared session state.
    static let defaultsKey = "input.privateEventSource"

    static func privateStateEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    /// Nil means the combined session state, as before this source existed.
    static func make(privateState: Bool) -> CGEventSource? {
        guard privateState, let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = RemoteInputTag.value
        return source
    }

    static let shared: CGEventSource? = make(privateState: privateStateEnabled())
}

/// Mouse buttons the phone can press, with the Mac's button numbers: 3 and 4 are the side
/// buttons browsers, Finder and Xcode read as Back and Forward.
enum RemoteMouseButton: String, CaseIterable {
    case left, right, center, back, forward

    var cgButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .center: .center
        case .back: CGMouseButton(rawValue: 3)!
        case .forward: CGMouseButton(rawValue: 4)!
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .center, .back, .forward: .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .center, .back, .forward: .otherMouseUp
        }
    }

    /// The `key` of an `auxClick` action.
    static func auxiliary(_ name: String) -> RemoteMouseButton? {
        AuxiliaryMouseButton(rawValue: name).map { $0 == .back ? .back : .forward }
    }
}

/// Scroll-wheel phase fields for a wire phase. A gesture phase and a momentum phase are never set
/// together: macOS sends the fingers' phases first, then momentum with the gesture phase at zero.
enum ScrollEventPhases {
    static func values(for phase: String) -> (scroll: Int64, momentum: Int64) {
        switch phase {
        case "began": (Int64(CGScrollPhase.began.rawValue), 0)
        case "changed": (Int64(CGScrollPhase.changed.rawValue), 0)
        case "ended": (Int64(CGScrollPhase.ended.rawValue), 0)
        case "cancelled": (Int64(CGScrollPhase.cancelled.rawValue), 0)
        case ScrollMomentumPhase.began.rawValue: (0, Int64(CGMomentumScrollPhase.begin.rawValue))
        case ScrollMomentumPhase.changed.rawValue: (0, Int64(CGMomentumScrollPhase.continuous.rawValue))
        case ScrollMomentumPhase.ended.rawValue: (0, Int64(CGMomentumScrollPhase.end.rawValue))
        default: (0, 0)
        }
    }
}

/// Admits the momentum that follows one finished scroll gesture, and decides when it must end.
/// Momentum may only continue the stream whose fingers just lifted, only once, and stops the moment
/// anything else happens: new input, a quiet stream, a new session or a disconnect.
struct ScrollMomentumGate {
    /// How long after the fingers lift the phone's first momentum event may arrive.
    static let startWindow: TimeInterval = 0.35
    /// Silence after which a running momentum is stale, like a gesture stream.
    static let idleLimit: TimeInterval = 0.5

    private(set) var candidate: String?
    private var candidateUntil: TimeInterval = 0
    private(set) var active: String?
    private var deadline: TimeInterval = 0

    enum Verdict: Equatable { case post, reject }

    mutating func gestureEnded(stream: String, at now: TimeInterval) {
        candidate = stream
        candidateUntil = now + Self.startWindow
    }

    mutating func admit(_ phase: ScrollMomentumPhase, stream: String, at now: TimeInterval) -> Verdict {
        switch phase {
        case .began:
            guard active == nil, candidate == stream, now < candidateUntil else { return .reject }
            candidate = nil
            active = stream
            deadline = now + Self.idleLimit
            return .post
        case .changed:
            guard active == stream, now < deadline else { return .reject }
            deadline = now + Self.idleLimit
            return .post
        case .ended:
            guard active == stream else { return .reject }
            active = nil
            return .post
        }
    }

    /// True when a running momentum was cut short and the Mac needs its end event.
    mutating func interrupt() -> Bool {
        candidate = nil
        guard active != nil else { return false }
        active = nil
        return true
    }

    /// True when a running momentum went quiet and must be ended.
    mutating func expire(at now: TimeInterval) -> Bool {
        if candidate != nil, now >= candidateUntil { candidate = nil }
        guard active != nil, now >= deadline else { return false }
        active = nil
        return true
    }
}
