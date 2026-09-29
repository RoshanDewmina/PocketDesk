import Foundation

/// Capabilities a host advertises on its `capture` status messages. A phone only sends an
/// extension action after seeing the matching feature, so older hosts never receive an
/// action name their validator would reject.
enum SessionFeature {
    static let clipboardText = "clipboard.text.1"
    static let backgroundPause = "pause.1"
    static let displayWake = "display.wake.1"
    static let host = [clipboardText, backgroundPause, displayWake]
}

/// Availability the Mac itself reports on `capture` status. The phone states only these as
/// fact; without one, it must not guess whether the Mac is asleep or locked.
enum HostPresence: String {
    case displayAsleep, sleeping, locked, switchedUser
}

extension RemoteAction {
    static let sessionExtensionActions: Set<String> = ["clipboard", "pause", "resume", "wake"]

    /// Validates the appended clipboard/pause/presence fields. Returns true when the action is a
    /// session-extension action that is now fully validated.
    func validateSessionExtension() throws -> Bool {
        if let features {
            guard action == "capture", features.count <= 16, features.allSatisfy(Self.isFeatureName) else {
                throw RemoteError.invalidMessage
            }
        }
        if let hostState {
            guard action == "capture", ClipboardFrame.isWellFormedStatus(hostState) else { throw RemoteError.invalidMessage }
        }
        guard Self.sessionExtensionActions.contains(action) else {
            guard clipboard == nil else { throw RemoteError.invalidMessage }
            return false
        }
        guard interaction == nil, pointerLocatorSupported == nil, pointerProbe == nil, pointerLocation == nil,
              pointerSync == nil, streamQuality == nil, textFocusProbe == nil, textFocusEditable == nil,
              x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty
        else { throw RemoteError.invalidMessage }
        if action == "clipboard" {
            guard let clipboard else { throw RemoteError.invalidMessage }
            try clipboard.validate()
        } else if clipboard != nil {
            throw RemoteError.invalidMessage
        }
        return true
    }

    private static func isFeatureName(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
        }
    }
}

/// Host-side reservation for a phone that announced it is backgrounding. Capture stops
/// immediately; the peer and its session slot stay reserved until the grace period ends.
struct HostPhonePause {
    static let grace: TimeInterval = 45
    private(set) var since: TimeInterval?

    var isPaused: Bool { since != nil }

    mutating func begin(at now: TimeInterval) {
        if since == nil { since = now }
    }

    mutating func clear() {
        since = nil
    }

    func isExpired(at now: TimeInterval, grace: TimeInterval = Self.grace) -> Bool {
        guard let since else { return false }
        return now - since >= grace
    }
}

/// Phone-side decisions for leaving and returning to the foreground. iOS gives a backgrounded
/// app only a short, finite task-completion window, so a live session is held just long enough
/// to survive a quick app switch, then closed cleanly and re-established on return.
struct BackgroundContinuity {
    static let maximumHold: TimeInterval = 25
    static let expirationMargin: TimeInterval = 5
    static let minimumHold: TimeInterval = 2
    static let automaticResumeWindow: TimeInterval = 15 * 60

    enum Phase: Equatable {
        case foreground
        case holding(since: TimeInterval)
        case released(since: TimeInterval)
    }

    enum EntryDecision: Equatable {
        case none
        case hold(seconds: TimeInterval)
        case release
    }

    enum ReturnDecision: Equatable {
        case none
        case resumeHeldSession
        case reconnect
        case offerReconnect
    }

    private(set) var phase: Phase = .foreground

    var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    /// - Parameters:
    ///   - sessionOpen: a session is connected, connecting or visibly in progress.
    ///   - canHold: the session is connected, the host can pause video and iOS granted background time.
    ///   - budget: remaining background time reported by iOS, when known.
    mutating func enterBackground(at now: TimeInterval, sessionOpen: Bool, canHold: Bool,
                                  budget: TimeInterval?) -> EntryDecision {
        guard phase == .foreground, sessionOpen else { return .none }
        if canHold {
            let available = (budget ?? .infinity) - Self.expirationMargin
            let seconds = min(Self.maximumHold, available)
            if seconds >= Self.minimumHold {
                phase = .holding(since: now)
                return .hold(seconds: seconds)
            }
        }
        phase = .released(since: now)
        return .release
    }

    /// The hold timer, the iOS expiration handler or a transport loss ended the held session.
    @discardableResult
    mutating func endHold() -> Bool {
        guard case .holding(let since) = phase else { return false }
        phase = .released(since: since)
        return true
    }

    mutating func returnToForeground(at now: TimeInterval, sessionConnected: Bool) -> ReturnDecision {
        let previous = phase
        phase = .foreground
        switch previous {
        case .foreground:
            return .none
        case .holding(let since):
            if sessionConnected { return .resumeHeldSession }
            return now - since <= Self.automaticResumeWindow ? .reconnect : .offerReconnect
        case .released(let since):
            return now - since <= Self.automaticResumeWindow ? .reconnect : .offerReconnect
        }
    }

    mutating func reset() {
        phase = .foreground
    }
}
