import Foundation

/// One plain answer to "what is wrong, and what do I do?", with exactly one next step.
///
/// Built only from what Farside observed: the coordinator's failure, the Mac's own account of why it
/// left or what its display is doing, picture and capture freshness, a reachability check, and the
/// measured route. Silence is never given a cause: an unanswered attempt stays "cause unknown".
struct ConnectionHealth: Equatable {
    enum State: String, Equatable {
        case macAsleep, macLocked, otherUser, displayAsleep, sharingStopped, pictureStalled, reconnecting,
             needsAnywhere, anywhereUnconfirmed, relayUnavailable, relaySlow, networkSlow, sessionClosing,
             macBusy, notApproved, stoppedToStaySafe, pairingProblem, serviceUnreachable, macAnswering,
             unreachable, screenRecordingOff, accessibilityOff
    }

    enum Action: Equatable {
        case none, retry, checkAgain, wakeDisplay, seePlans, pairAgain

        var title: String? {
            switch self {
            case .none: nil
            case .retry: "Try again"
            case .checkAgain: "Check again"
            case .wakeDisplay: "Wake display"
            case .seePlans: "See Farside Anywhere"
            case .pairAgain: "Pair again"
            }
        }
    }

    /// A network round trip at or above this is reported as slow.
    static let slowRoundTripMs = 150

    let state: State
    /// Short enough for a status line.
    let title: String
    /// What Farside actually saw.
    let detail: String
    /// The one thing to do next.
    let nextStep: String
    var action: Action = .none

    /// True when the cause is not known, only that nothing answered.
    var causeUnknown: Bool { state == .unreachable || state == .pictureStalled }

    // MARK: Before a session: what the last attempt ended with

    static func after(_ failure: FriendlyError) -> ConnectionHealth {
        let step = failure.fix
        switch failure.kind {
        case .napping:
            return ConnectionHealth(state: .macAsleep, title: "Mac asleep", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .locked:
            return ConnectionHealth(state: .macLocked, title: "Mac locked", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .switchedUser:
            return ConnectionHealth(state: .otherUser, title: "Another user on the Mac", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .screenSharingOff:
            return ConnectionHealth(state: .sharingStopped, title: "Mac stopped sharing its screen",
                                    detail: "Your Mac reported that its screen capture stopped.",
                                    nextStep: step)
        case .screenRecordingOff:
            return ConnectionHealth(state: .screenRecordingOff, title: failure.headline,
                                    detail: failure.message, nextStep: failure.fix, action: .retry)
        case .needsPlan:
            return ConnectionHealth(state: .needsAnywhere, title: "Different network · Anywhere needed",
                                    detail: "Farside’s service allowed only a same-network route, and your Mac didn’t answer on it.",
                                    nextStep: "Join your Mac’s Wi-Fi, or use Farside Anywhere from any network.",
                                    action: .seePlans)
        case .anywhereUnverified:
            return ConnectionHealth(state: .anywhereUnconfirmed, title: "Anywhere not confirmed", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .relayUnavailable, .serviceNotReady:
            return ConnectionHealth(state: .relayUnavailable, title: "Relay unavailable", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .busy:
            return ConnectionHealth(state: .sessionClosing, title: "Last session still closing", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .declined, .approvalTimedOut:
            return ConnectionHealth(state: .notApproved, title: failure.shortStatus, detail: failure.message,
                                    nextStep: step, action: failure.action == .pairAgain ? .pairAgain : .retry)
        case .verifyFailed, .sessionGlitch:
            return ConnectionHealth(state: .stoppedToStaySafe, title: "Stopped to stay safe", detail: failure.message,
                                    nextStep: step, action: .retry)
        case .keychain, .codeRejected:
            return ConnectionHealth(state: .pairingProblem, title: failure.shortStatus, detail: failure.message,
                                    nextStep: step, action: failure.action == .pairAgain ? .pairAgain : .retry)
        case .unreachable:
            return unreachable(detail: "Your Mac didn’t answer. Farside can’t tell whether it’s asleep, offline or quit.")
        case .connectionLost:
            return unreachable(detail: "The connection dropped and retrying didn’t bring it back. The cause is unknown.")
        }
    }

    static func unreachable(detail: String) -> ConnectionHealth {
        ConnectionHealth(state: .unreachable, title: "Unreachable · cause unknown", detail: detail,
                         nextStep: "Check that your Mac is awake and Farside is in its menu bar.",
                         action: .checkAgain)
    }

    // MARK: A reachability check (no session, no control)

    static func checked(_ outcome: MacReachabilityProbe.Outcome, lastReached: String?) -> ConnectionHealth {
        switch outcome {
        case .answering:
            return ConnectionHealth(state: .macAnswering, title: "Mac answering now",
                                    detail: "Farside on your Mac answered just now.",
                                    nextStep: "Tap Connect.")
        case .notAnswering:
            let since = lastReached.map { " Last reached \($0)." } ?? ""
            return unreachable(detail: "Your Mac’s Farside isn’t answering. It may be asleep, off, offline or quit; Farside can’t tell which.\(since)")
        case .sessionBusy:
            return ConnectionHealth(state: .macBusy, title: "Another session is open",
                                    detail: "A phone is already connected to your Mac.",
                                    nextStep: "Try again in a moment.", action: .checkAgain)
        case .serviceUnreachable:
            return ConnectionHealth(state: .serviceUnreachable, title: "Can’t reach Farside’s service",
                                    detail: "Farside’s connection service didn’t answer this iPhone.",
                                    nextStep: "Check that this iPhone is online.", action: .checkAgain)
        }
    }

    // MARK: During a session

    struct SessionEvidence: Equatable {
        var connected: Bool
        var fresh: Bool
        var captureHealthy: Bool
        var hostPresence: HostPresence?
        var canWakeDisplay = false
        /// "Direct" or "Relay" from the stream statistics.
        var route: String?
        var roundTripMs: Int?
        /// A grant the Mac reported missing during the session.
        var blocker: MacShareBlocker?
    }

    /// Nil while nothing is wrong. Order matters: a dropped connection explains a stalled picture,
    /// and the Mac's own report explains a stopped capture better than a guess would.
    static func session(_ evidence: SessionEvidence) -> ConnectionHealth? {
        guard evidence.connected else {
            return ConnectionHealth(state: .reconnecting, title: "Reconnecting",
                                    detail: "The connection dropped. Farside is retrying by itself and resends nothing you typed or clicked.",
                                    nextStep: "Wait a moment, or tap End to stop.")
        }
        if evidence.hostPresence == .displayAsleep {
            return ConnectionHealth(state: .displayAsleep, title: "Mac display asleep",
                                    detail: "Your Mac reported that its display went to sleep.",
                                    nextStep: evidence.canWakeDisplay ? "Tap Wake display." : "Press a key on the Mac to wake it.",
                                    action: evidence.canWakeDisplay ? .wakeDisplay : .none)
        }
        if evidence.fresh && !evidence.captureHealthy {
            return ConnectionHealth(state: .sharingStopped, title: "Mac stopped sharing its screen",
                                    detail: "Your Mac reported that its screen capture stopped. Controls are paused.",
                                    nextStep: FriendlyError.screenSharingOff.fix)
        }
        if !evidence.fresh {
            return ConnectionHealth(state: .pictureStalled, title: "Picture paused",
                                    detail: "No new picture has arrived for a moment. The cause is unknown. Controls are paused.",
                                    nextStep: "Wait for it to return, or end and reconnect.")
        }
        if evidence.blocker == .accessibilityOff {
            return ConnectionHealth(state: .accessibilityOff, title: "Accessibility is off on your Mac",
                                    detail: "Your Mac reported that Farside there isn’t allowed to control it, so this session is view only.",
                                    nextStep: "On your Mac: System Settings → Privacy & Security → Accessibility → Farside.")
        }
        if let rtt = evidence.roundTripMs, rtt >= slowRoundTripMs {
            if evidence.route == "Relay" {
                return ConnectionHealth(state: .relaySlow, title: "Relay slow",
                                        detail: "Relayed route, \(rtt) ms round trip.",
                                        nextStep: "On your Mac’s Wi-Fi, Farside can connect directly.")
            }
            let route = evidence.route == "Direct" ? "Direct route, " : ""
            return ConnectionHealth(state: .networkSlow, title: "Network slow",
                                    detail: "\(route)\(rtt) ms round trip.",
                                    nextStep: "A stronger Wi-Fi or cellular signal usually helps.")
        }
        return nil
    }

    /// The session works, only slowly: control state stays the more useful line until a click is acknowledged.
    var isSlowOnly: Bool { state == .relaySlow || state == .networkSlow }

    /// The dock's one-line summary.
    var sessionLine: String {
        switch state {
        case .sharingStopped, .pictureStalled: "\(title) · controls paused"
        default: "\(title) · \(nextStep)"
        }
    }
}
