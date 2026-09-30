import Foundation

/// Capabilities a host advertises on its `capture` status messages. A phone only sends an
/// extension action after seeing the matching feature, so older hosts never receive an
/// action name their validator would reject.
enum SessionFeature {
    static let clipboardText = "clipboard.text.1"
    static let backgroundPause = "pause.1"
    static let displayWake = "display.wake.1"
    static let privacyCurtain = "curtain.1"
    /// `moveTo` (display-local absolute pointer placement), triple-click counts and hardware
    /// modifier flags on pointer actions. Direct touch and a hardware pointer need it.
    static let absolutePointer = "pointer.absolute.1"
    /// `middle`: a middle-button click at the pointer.
    static let middleButton = "pointer.middle.1"
    /// Key names beyond the original set: digits, punctuation, F1–F20, navigation and keypad keys.
    static let extendedKeys = "keys.extended.1"
    /// `displays` (list) and `display` (switch the streamed display within the session).
    static let displaySelection = "display.select.1"
    /// G4: the Mac crops the capture to the phone's `viewport` and echoes `captureRegion`.
    static let viewportCapture = "capture.viewport.1"
    /// G12: the Mac reports its ladder rung and busy state on `capture` status.
    static let ladder = "ladder.1"
    /// Momentum phases after a scroll gesture's `ended` (`ScrollMomentumPhase`).
    static let momentumScroll = "scroll.momentum.1"
    /// `auxClick`: a mouse's Back and Forward side buttons.
    static let auxiliaryButtons = "pointer.aux.1"
    /// `textFocusSecure` on a focus reply: the focused field takes a password.
    static let secureFocus = "focus.secure.1"
    /// `file` actions and the `file` data channel: one file each way, and links from the share sheet.
    static let fileTransfer = "file.1"
    /// A requested focused field rect, without contents or labels.
    static let focusGeometry = "focus.rect.1"
    static let host = [clipboardText, backgroundPause, displayWake, privacyCurtain,
                       absolutePointer, middleButton, extendedKeys, displaySelection, viewportCapture, ladder,
                       momentumScroll, auxiliaryButtons, secureFocus, fileTransfer, focusGeometry]
}

/// Availability the Mac itself reports on `capture` status. The phone states only these as
/// fact; without one, it must not guess whether the Mac is asleep or locked.
enum HostPresence: String {
    case displayAsleep, sleeping, locked, switchedUser
}

/// The Mac's privacy curtain as reported on `capture` status. Unknown values mean "off".
enum PrivacyCurtainState: String, Equatable {
    /// The preference is off.
    case off
    /// On, waiting for a healthy picture before covering the Mac.
    case pending
    /// Every display is covered; the phone still sees the desktop.
    case up
    /// Someone at the Mac lifted it for this session.
    case liftedLocally
    /// On, but the Mac lacks Accessibility, which the local Escape shortcut needs.
    case unavailable
    /// The Mac could not confirm the curtain was hidden from the stream, so it stayed down.
    case failed

    /// The phone's toggle reflects the Mac's preference, not whether the screen is covered now.
    var preferenceOn: Bool { self != .off }
}

/// Values a phone may request with the `curtain` action.
enum PrivacyCurtainRequest: String {
    case up, down
}

/// One-shot facts about the Mac app itself, reported on `capture` status.
enum HostLifecycleEvent: String {
    /// Farside on the Mac restarted after it quit unexpectedly or stopped responding.
    case recovered
}

/// Short-lived explanations the phone shows over a live session.
enum PhoneSessionNotice {
    static let hostRecovered = "Your Mac’s Farside restarted — reconnected."
    static let curtainLiftedLocally = "Someone at your Mac lifted the privacy curtain."
    static let curtainFailed = "Your Mac couldn’t hide its screen safely, so it stayed visible."

    /// What changed on the Mac between two `capture` reports, if it is worth telling the person.
    static func curtainChange(from previous: PrivacyCurtainState?, to current: PrivacyCurtainState?) -> String? {
        guard previous != current else { return nil }
        switch current {
        case .liftedLocally where previous == .up: return curtainLiftedLocally
        case .failed: return curtainFailed
        default: return nil
        }
    }
}

extension RemoteAction {
    static let sessionExtensionActions: Set<String> = ["clipboard", "pause", "resume", "wake", "curtain", "file"]

    /// Validates the appended clipboard/pause/presence/curtain fields. Returns true when the action
    /// is a session-extension action that is now fully validated.
    func validateSessionExtension() throws -> Bool {
        if let features {
            guard action == "capture", features.count <= 16, features.allSatisfy(Self.isFeatureName) else {
                throw RemoteError.invalidMessage
            }
        }
        if let hostState {
            guard action == "capture", ClipboardFrame.isWellFormedStatus(hostState) else { throw RemoteError.invalidMessage }
        }
        if let hostEvent {
            guard action == "capture", ClipboardFrame.isWellFormedStatus(hostEvent) else { throw RemoteError.invalidMessage }
        }
        if let curtain {
            guard action == "capture" || action == "curtain", ClipboardFrame.isWellFormedStatus(curtain) else {
                throw RemoteError.invalidMessage
            }
        }
        if let agentAlert {
            guard action == "capture" else { throw RemoteError.invalidMessage }
            try agentAlert.validate()
        }
        guard Self.sessionExtensionActions.contains(action) else {
            guard clipboard == nil, file == nil else { throw RemoteError.invalidMessage }
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
        if action == "file" {
            guard let file else { throw RemoteError.invalidMessage }
            try file.validate()
        } else if file != nil {
            throw RemoteError.invalidMessage
        }
        if action == "curtain" {
            guard let curtain, PrivacyCurtainRequest(rawValue: curtain) != nil else { throw RemoteError.invalidMessage }
        } else if curtain != nil {
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
