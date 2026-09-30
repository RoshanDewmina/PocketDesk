import Foundation

/// A grant the Mac is missing, as the Mac itself knows it. Told only to a phone whose handshake request
/// lists `feature`, so an older phone never receives a value it cannot read.
///
/// - `screenRecordingOff`: the Mac stays reachable but refuses every session; nothing is streamed.
/// - `accessibilityOff`: rides `hostState` on `capture` status while control is allowed but not
///   possible; the session stays view only and the Mac accepts no input.
enum MacShareBlocker: String, Codable, Equatable {
    case screenRecordingOff
    case accessibilityOff

    static let feature = "blocker.1"
    /// The protected-message kind a Mac sends instead of accepting a session.
    static let refusalKind = "unavailable"

    struct Refusal: Codable, Equatable {
        var reason: MacShareBlocker
    }

    /// The phone's handshake request body. Older Macs ignore a request body.
    struct Handshake: Codable, Equatable {
        var features: [String]

        static let phone = Handshake(features: [MacShareBlocker.feature])

        /// At most eight short names; anything else counts as no features.
        static func features(in body: Data?) -> Set<String> {
            guard let body, body.count <= 1024,
                  let decoded = try? JSONDecoder().decode(Handshake.self, from: body),
                  decoded.features.count <= 8 else { return [] }
            return Set(decoded.features.filter { (1...32).contains($0.utf8.count) })
        }
    }

    /// A Mac that wants to share but lacks Screen Recording still registers with the service, so its
    /// phone hears why instead of silence. It never captures or accepts a session in this state.
    static func shouldListenWithoutSharing(wantsSharing: Bool, suppressed: Bool, sharingActive: Bool,
                                           listening: Bool, otherAccessRunning: Bool,
                                           screenRecordingGranted: Bool, hasPairedPhone: Bool,
                                           serviceConfigured: Bool) -> Bool {
        wantsSharing && !suppressed && !sharingActive && !listening && !otherAccessRunning
            && !screenRecordingGranted && hasPairedPhone && serviceConfigured
    }

    /// What the Mac puts in `hostState` for a phone that understands blockers. The Mac's own
    /// availability report always wins; a view-only session caused by Accessibility comes last.
    static func sessionState(presence: HostPresence?, phoneUnderstands: Bool, controlAllowed: Bool,
                             accessibilityGranted: Bool) -> String? {
        if let presence { return presence.rawValue }
        guard phoneUnderstands, controlAllowed, !accessibilityGranted else { return nil }
        return MacShareBlocker.accessibilityOff.rawValue
    }
}
