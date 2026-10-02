import Foundation

/// A grant the Mac is missing, as the Mac itself knows it. Told only to a phone whose handshake request
/// lists `feature`, so an older phone never receives a value it cannot read.
///
/// - `screenRecordingOff`: the Mac stays reachable but refuses every session; nothing is streamed.
/// - `accessibilityOff`: rides `hostState` on `capture` status while control is allowed but not
///   possible; the session stays view only and the Mac accepts no input.
/// - `screenRecordingApproval`: the grant exists but macOS stopped or declined the capture until
///   someone at the Mac approves it. Told only to a phone that lists `approvalFeature`; a phone that
///   lists only `feature` hears `screenRecordingOff`, the nearest reason it can read.
enum MacShareBlocker: String, Codable, Equatable {
    case screenRecordingOff
    case accessibilityOff
    case screenRecordingApproval

    static let feature = "blocker.1"
    static let approvalFeature = "blocker.2"
    /// The protected-message kind a Mac sends instead of accepting a session.
    static let refusalKind = "unavailable"

    struct Refusal: Codable, Equatable {
        var reason: MacShareBlocker
    }

    /// The phone's handshake request body. Older Macs ignore a request body.
    struct Handshake: Codable, Equatable {
        var features: [String]
        var mode: String? = nil
        /// Opt-in requests outside the eight-name feature bound. Older Macs ignore the key, and too
        /// many options are dropped on their own without touching `features`.
        var options: [String]? = nil
        static let maximumOptions = 4
        /// Only known opt-ins; an option can never stand in for a feature such as causal input.
        static let knownOptions: Set<String> = [SessionFeature.textClarity, SessionFeature.clipboardSync, SessionFeature.phoneAudio]

        static let phone = Handshake(features: [MacShareBlocker.feature, MacShareBlocker.approvalFeature, SessionFeature.extendedFeatureList, SessionFeature.causalInput, SessionFeature.pencilInput, SessionFeature.videoLTR, SessionFeature.exactVideoTiming])
        /// Refinement rides in `features` so a Mac that predates `options` still honours it; text
        /// clarity only exists on Macs that read `options`.
        static func phoneRequest(_ optional: [String], mode: String? = nil, defaults: UserDefaults = .standard) -> Handshake {
            let options = (optional.contains(SessionFeature.textClarity) ? [SessionFeature.textClarity] : [])
                + (!defaults.bool(forKey: "clipboardAutoSyncDisabled") ? [SessionFeature.clipboardSync] : [])
                + (!defaults.bool(forKey: "phoneAudioRequestDisabled") ? [SessionFeature.phoneAudio] : [])
            return Handshake(features: phone.features + (optional.contains(SessionFeature.videoRefinement) ? [SessionFeature.videoRefinement] : []),
                             mode: mode, options: options.isEmpty ? nil : options)
        }
        var requested: Set<String> { Set(features + (options ?? [])) }

        static func requestedMode(in body: Data?) -> SessionMode {
            guard let body, body.count <= 1024,
                  let decoded = try? JSONDecoder().decode(Handshake.self, from: body),
                  decoded.features.count <= 8 else { return .picture }
            return decoded.mode.flatMap(SessionMode.init(rawValue:)) ?? .picture
        }

        /// At most eight short names, plus at most four options of which only known opt-ins count;
        /// too many features counts as no features, too many options as no options.
        static func features(in body: Data?) -> Set<String> {
            guard let body, body.count <= 1024,
                  let decoded = try? JSONDecoder().decode(Handshake.self, from: body),
                  decoded.features.count <= 8 else { return [] }
            let options = (decoded.options?.count ?? 0) <= maximumOptions ? (decoded.options ?? []).filter(knownOptions.contains) : []
            return Set((decoded.features + options).filter { (1...32).contains($0.utf8.count) })
        }
    }

    /// The reason as this phone can read it, or nil for a phone that lists no blocker feature.
    func told(to features: Set<String>) -> MacShareBlocker? {
        guard features.contains(Self.feature) || features.contains(Self.approvalFeature) else { return nil }
        if self == .screenRecordingApproval && !features.contains(Self.approvalFeature) { return .screenRecordingOff }
        return self
    }

    /// The Mac's own account of what stops it sharing, strongest first.
    static func current(screenRecordingGranted: Bool, captureApprovalPending: Bool) -> MacShareBlocker? {
        if !screenRecordingGranted { return .screenRecordingOff }
        return captureApprovalPending ? .screenRecordingApproval : nil
    }

    /// A Mac that wants to share but lacks Screen Recording, or waits for its capture to be approved,
    /// still registers with the service, so its phone hears why instead of silence. It never captures
    /// or accepts a session in this state.
    static func shouldListenWithoutSharing(wantsSharing: Bool, suppressed: Bool, sharingActive: Bool,
                                           listening: Bool, otherAccessRunning: Bool,
                                           screenRecordingGranted: Bool, captureApprovalPending: Bool = false,
                                           hasPairedPhone: Bool, serviceConfigured: Bool) -> Bool {
        wantsSharing && !suppressed && !sharingActive && !listening && !otherAccessRunning
            && current(screenRecordingGranted: screenRecordingGranted, captureApprovalPending: captureApprovalPending) != nil
            && hasPairedPhone && serviceConfigured
    }

    /// What the Mac puts in `hostState` for a phone that understands blockers. The Mac's own
    /// availability report always wins; a capture waiting for approval comes next, and a view-only
    /// session caused by Accessibility comes last.
    static func sessionState(presence: HostPresence?, phoneUnderstands: Bool, controlAllowed: Bool,
                             accessibilityGranted: Bool, captureApprovalPending: Bool = false,
                             phoneUnderstandsApproval: Bool = false) -> String? {
        if let presence { return presence.rawValue }
        if captureApprovalPending && phoneUnderstandsApproval { return MacShareBlocker.screenRecordingApproval.rawValue }
        guard phoneUnderstands, controlAllowed, !accessibilityGranted else { return nil }
        return MacShareBlocker.accessibilityOff.rawValue
    }
}
