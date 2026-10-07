import Foundation

/// Capabilities a host advertises on its `capture` status messages. A phone only sends an
/// extension action after seeing the matching feature, so older hosts never receive an
/// action name their validator would reject.
enum SessionFeature {
  static let liveViewOnly = "viewOnlyLive.2"
    static let shortcutChips = "app.shortcuts.1"
    static let extendedFeatureList = "features.32"
    static let lowDataPolicy = "network.lowData.1"
    static let phoneAudio = "audio.listen.1"
    static let causalInput = "input.causal.1"
    static let lanWake = "wake.helper.1"
    static let inputReceipt = "input.receipt.1"
    static let captureScope = "capture-scope-v1"
    static let videoLTR = "video.ltr.1"
    static let videoRefinement = "video.refine.1"
    static let exactVideoTiming = "video.timing.1"
    /// Phone request only: a still-picture QP floor on the Mac's owned encoder. Never advertised by the host.
    static let textClarity = "video.clarity.1"
    /// Phone request only: this phone's owned HEVC decoder asks for a key frame itself when a decode fails
    /// (`OwnedHEVCDecoder` recovery), so the Mac's owned HEVC encoder may drop its 10 s safety key
    /// (`StreamTuning.keysOnDemand`); an H.264 session keeps it. Never advertised by the host. Travels as
    /// `Handshake.keysOnDemand`, outside the eight-feature and four-option bounds older Macs decode.
    static let keysOnDemand = "video.keys.ondemand.1"
    static let pencilInput = "input.pencil.1"
    static let clipboardText = "clipboard.text.1"
    static let clipboardSync = "clipboard.sync.1"
    static let backgroundPause = "pause.1"
    /// Opt-in reliable close request/receipt; absent peers retain ordinary disconnect behavior.
    static let deliberateEnd = "session.end.1"
    static let displayWake = "display.wake.1"
    static let privacyCurtain = "curtain.1"
    /// Advertised only when the host release gate and prerequisites allow Away mode.
    static let away = "away.1"
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
    /// The Mac runs the coast itself: `momentumBegan` carries the lift velocity in `x`/`y` (points per
    /// second) and the phone sends no `momentumChanged`. Requires `momentumScroll`.
    static let hostMomentum = "scroll.momentum.2"
    /// `auxClick`: a mouse's Back and Forward side buttons.
    static let auxiliaryButtons = "pointer.aux.1"
    /// `textFocusSecure` on a focus reply: the focused field takes a password.
    static let secureFocus = "focus.secure.1"
    /// `file` actions and the `file` data channel: one file each way, and links from the share sheet.
    static let fileTransfer = "file.1"
    /// A requested focused field rect, without contents or labels.
    static let focusGeometry = "focus.rect.1"
    /// Couch mode: trackpad and keys with no picture, on a proven local link. Advertised by the host itself, not in `host`.
    static let couch = "couch.1"
    static let displayScale = "display.scale.2"
  static let legacyHost = [clipboardText, backgroundPause, displayWake, privacyCurtain,
                       absolutePointer, middleButton, extendedKeys, displaySelection, viewportCapture, ladder,
                       momentumScroll, auxiliaryButtons, secureFocus, fileTransfer, focusGeometry, macVitals]
    static let host = [lowDataPolicy, phoneAudio, clipboardSync, causalInput, liveViewOnly, captureScope, inputReceipt, pencilInput, videoLTR, videoRefinement, exactVideoTiming, hostMomentum] + legacyHost
}

/// Phone kill switch for asking the Mac for keys on demand (launch argument
/// `-PocketDeskKeysOnDemandRequest NO`). On by default, so the Mac's `PocketDeskKeysOnDemand` alone
/// decides whether the 10 s key goes; off, the phone never asks and every Mac keeps it.
enum KeysOnDemandRequest {
    static let defaultsKey = "PocketDeskKeysOnDemandRequest"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }
}

/// Phone: offer to answer the Mac's one-hop local link proof on a remote (Anywhere) route
/// (`MacShareBlocker.Handshake.lanProof`; the Mac side is `StreamTuning.remoteRouteLANProof`).
/// Launch argument `-PocketDeskRemoteRouteLANProofRequest YES` (or the same defaults key), then relaunch.
/// Off by default: the phone never offers, and a Mac never sends it an endpoint on a remote route.
enum RemoteRouteLANProofRequest {
    static let defaultsKey = "PocketDeskRemoteRouteLANProofRequest"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

/// The first-minute flow is negotiated outside the capped feature list.
enum First60 {
    static let disabledDefaultsKey = "PocketDeskFirst60Disabled"
    static let finishedDefaultsKey = "PocketDeskFirst60SetupFinished"
    static let permissionTimeoutNanoseconds: UInt64 = 300_000_000_000
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledDefaultsKey)
    }
}

struct First60PermissionWait: Codable, Equatable {
    enum Stage: String, Codable { case screenRecording, accessibility }
    var stage: Stage
    var message: String {
        switch stage {
        case .screenRecording: "On your Mac, allow Screen Recording to see its screen."
        case .accessibility: "On your Mac, allow Accessibility to steer it."
        }
    }
}

/// Sealed, replay-checked Mac status. It conveys no input or route authority.
struct First60SetupStatus: Codable, Equatable {
    var version: Int = 1
    var open: Bool
    var permission: First60PermissionWait?
    var mediaReady: Bool
    func validate() throws {
        guard version == 1, open || permission == nil,
              mediaReady || permission?.stage == .screenRecording else { throw RemoteError.invalidMessage }
    }
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
    static let awayCovered = "Mac covered · requests a lock if touched"
    static let awayCantUnlock = "Away mode can’t unlock it."
    static let curtainFailed = "Your Mac couldn’t hide its screen safely, so it stayed visible."
    static let curtainUnavailable = "Your Mac can’t hide its screen until Farside has Accessibility there."

    /// What changed on the Mac between two `capture` reports, if it is worth telling the person.
    static func curtainChange(from previous: PrivacyCurtainState?, to current: PrivacyCurtainState?) -> String? {
        guard previous != current else { return nil }
        switch current {
        case .liftedLocally where previous == .up: return curtainLiftedLocally
        case .failed: return curtainFailed
        // Privacy mode is on by default, so a Mac that cannot apply it says so once per session.
        case .unavailable: return curtainUnavailable
        default: return nil
        }
    }
}

/// Internal rollback applies from the next handshake. No user-facing preference.
enum DeliberateSessionEnd {
    static let disabledDefaultsKey = "farsideDeliberateSessionEndDisabled"
    static let receiptTimeoutNanoseconds: UInt64 = 500_000_000
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledDefaultsKey)
    }

    /// Pause releases authority; its authenticated session identity is sufficient even when a
    /// display change overtook the phone's geometry status. Earlier peers retain the epoch guard.
    static func allowsBackgroundPause(epochMatches: Bool, connected: Bool, sharing: Bool,
                                      sessionRefused: Bool, ending: Bool, peerFeatures: Set<String>,
                                      enabled: Bool) -> Bool {
        guard connected, sharing, !sessionRefused, !ending else { return false }
        return epochMatches || (enabled && peerFeatures.contains(SessionFeature.deliberateEnd))
    }

    /// Resume can refer only to the current geometry or the exact pause this same session accepted.
    static func allowsForegroundResume(requestedEpoch: UInt64, currentEpoch: UInt64,
                                       acceptedPauseEpoch: UInt64?, paused: Bool, connected: Bool,
                                       sharing: Bool, sessionRefused: Bool, ending: Bool,
                                       peerFeatures: Set<String>, enabled: Bool) -> Bool {
        guard paused, connected, sharing, !sessionRefused, !ending else { return false }
        return requestedEpoch == currentEpoch || (enabled && peerFeatures.contains(SessionFeature.deliberateEnd)
            && acceptedPauseEpoch == requestedEpoch)
    }
}

extension RemoteAction {
    static let sessionExtensionActions: Set<String> = ["clipboard", "pause", "resume", "wake", "curtain", "file", "viewOnly", "lockMac", "sessionEnd"]

    /// Validates the appended clipboard/pause/presence/curtain fields. Returns true when the action
    /// is a session-extension action that is now fully validated.
    func validateSessionExtension() throws -> Bool {
        if let features {
            guard action == "capture", features.count <= 32, features.allSatisfy(Self.isFeatureName) else {
                throw RemoteError.invalidMessage
            }
        }
        if let hostState {
            guard action == "capture", ClipboardFrame.isWellFormedStatus(hostState) else { throw RemoteError.invalidMessage }
        }
        if let hostEvent {
            guard action == "capture", ClipboardFrame.isWellFormedStatus(hostEvent) else { throw RemoteError.invalidMessage }
        }
        if let away {
            guard action == "capture", AwayModeState(rawValue: away) != nil else { throw RemoteError.invalidMessage }
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
        guard (action == "viewOnly") == (liveViewOnly != nil) else { throw RemoteError.invalidMessage }
        if action == "sessionEnd" {
            // This lifecycle signal cannot smuggle unchecked fields through the extension early return.
            let allowed: Set<String> = ["action", "epoch", "x", "y", "text", "key", "modifiers"]
            guard epoch > 0,
                  let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
                  Set(encoded.keys).isSubset(of: allowed) else { throw RemoteError.invalidMessage }
        }
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
        case viewing(since: TimeInterval)
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
    var isViewing: Bool {
        if case .viewing = phase { return true }
        return false
    }

    /// PiP owns platform continuation, with no finite background task or hold timer.
    /// Retain only the same bounded foreground-return intent if that live consumer is lost.
    mutating func enterLiveBackground(at now: TimeInterval, sessionOpen: Bool) {
        guard phase == .foreground, sessionOpen else { return }
        phase = .viewing(since: now)
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
        let since: TimeInterval
        switch phase {
        case .holding(let began), .viewing(let began): since = began
        default: return false
        }
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
        case .viewing(let since):
            if sessionConnected { return .none }
            return now - since <= Self.automaticResumeWindow ? .reconnect : .offerReconnect
        case .released(let since):
            return now - since <= Self.automaticResumeWindow ? .reconnect : .offerReconnect
        }
    }

    mutating func reset() {
        phase = .foreground
    }
}

/// New peers need phone consent and the Mac veto; old phones keep explicit producer opt-in.
enum HostPhoneAudioPolicy {
    static func permits(negotiated: Bool, phoneRequested: Bool, macAllowed: Bool, legacyAllowed: Bool,
                        currentPicture: Bool, suspended: Bool, narrowScope: Bool) -> Bool {
        currentPicture && !suspended && !narrowScope &&
            (negotiated ? phoneRequested && macAllowed : legacyAllowed)
    }
}

/// Capture-queue-owned PCM admission, independent of whether an SCK update succeeds.
struct HostAudioCaptureEpoch {
    private(set) var epoch: UInt64?
    mutating func arm(allowed: Bool, begin: () -> UInt64) {
        guard allowed, epoch == nil else { return }
        let next = begin()
        epoch = next == 0 ? nil : next
    }
    mutating func retire(end: (UInt64) -> Void) {
        if let epoch { end(epoch) }
        epoch = nil
    }
}

/// Internal combined-test rollback; absent is ON. Applied on both peers, never a setting.
enum ShortcutChips {
    static let defaultsKey = "FarsideShortcutChips"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }
    static func advertised(addingTo features: [String], enabled: Bool, peerFeatures: Set<String>) -> [String] {
        guard negotiated(enabled: enabled, peerFeatures: peerFeatures),
              peerFeatures.contains(SessionFeature.extendedFeatureList), features.count < 32 else { return features }
        return features + [SessionFeature.shortcutChips]
    }
    static func negotiated(enabled: Bool, peerFeatures: Set<String>) -> Bool {
        enabled && peerFeatures.contains(SessionFeature.shortcutChips)
    }
}

/// App identity only. No window title, document name, field label or content.
struct FrontmostApp: Codable, Equatable, Sendable {
    /// Nil identity explicitly restores generic chips when an app exposes no usable metadata.
    var bundleID: String?
    var displayName: String?
    func validate() throws {
        if let bundleID {
            guard (1...255).contains(bundleID.utf8.count),
                  bundleID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") })
            else { throw RemoteError.invalidMessage }
        }
        if let displayName {
            guard (1...128).contains(displayName.utf8.count),
                  !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw RemoteError.invalidMessage }
        }
    }
}

/// Main-actor publisher: coalesce transient app switches and remember only successful delivery.
struct FrontmostAppPublication {
    private(set) var candidate: FrontmostApp?
    private var changedAt: TimeInterval = 0
    private var sent: FrontmostApp?
    mutating func observe(_ app: FrontmostApp?, at now: TimeInterval, allowed: Bool) {
        guard allowed else { self = Self(); return }
        if candidate != app { candidate = app; changedAt = now }
    }
    func pending(at now: TimeInterval, secure: Bool) -> FrontmostApp? {
        guard !secure, now >= changedAt + 0.25, candidate != sent else { return nil }
        return candidate
    }
    mutating func delivered(_ app: FrontmostApp) { sent = app }
}
