import Foundation

/// A "needs you" alert as the Mac sends it to a connected phone over the control channel, riding on a
/// `capture` status message the way `hostEvent` does. A phone that does not know the field ignores it,
/// so an older phone is never sent an action its validator would reject (which would end its session).
///
/// It carries a request id, an agent kind and an event name, all from short fixed vocabularies, and the
/// time it was raised. It never carries the agent's own words.
struct AgentAlertFrame: Codable, Equatable {
    var version = 1
    var id: String
    var kind: String
    var event: String
    /// Unix seconds.
    var raisedAt: Int
    /// Opaque per-run hash; absent on legacy attention frames.
    var runHash: String?

    init(id: String, kind: AgentKind, event: AgentAlertEvent, raisedAt: Date, runHash: String? = nil) {
        self.runHash = runHash
        self.id = id
        self.kind = kind.rawValue
        self.event = event.rawValue
        self.raisedAt = Int(raisedAt.timeIntervalSince1970.rounded())
    }

    /// Shape only. Unknown kinds and events are well formed and are interpreted (as "An agent", or ignored)
    /// by the phone: a newer Mac must not be able to end an older phone's session with a new word.
    func validate() throws {
        guard (1...16).contains(version), Self.isToken(id, max: 64), Self.isWord(kind), Self.isWord(event),
              (runHash == nil || AgentAlert.isSessionHash(runHash!)),
              (0...4_102_444_800).contains(raisedAt) else { throw RemoteError.invalidMessage }
    }

    static func isToken(_ value: String, max: Int) -> Bool {
        (1...max).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }

    static func isWord(_ value: String) -> Bool {
        (1...24).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }

    var agentKind: AgentKind { AgentKind(wire: kind) }
    var alertEvent: AgentAlertEvent? { AgentAlertEvent(rawValue: event) }
    var raisedDate: Date { Date(timeIntervalSince1970: TimeInterval(raisedAt)) }
    /// Only version 1 frames are interpreted.
    var isUnderstood: Bool { version == 1 && alertEvent != nil }
}

/// One alert a hook reported to the Mac, before it is forwarded anywhere.
struct AgentAlert: Equatable, Sendable {
    var id: String
    var kind: AgentKind
    var event: AgentAlertEvent
    /// A short hash of the agent's session id, for collapsing repeats. Never the id itself.
    var sessionHash: String
    var raisedAt: Date
    var runHash: String? = nil

    var frame: AgentAlertFrame {
        AgentAlertFrame(id: id, kind: kind, event: event, raisedAt: raisedAt, runHash: runHash)
    }

    static func isSessionHash(_ value: String) -> Bool {
        (8...16).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// `h_` plus 12 random hex digits: unguessable, and short enough for a notification payload.
    static func makeID() -> String {
        let bytes = (try? SecureRandom.bytes()) ?? Data(UUID().uuidString.utf8)
        return "h_" + bytes.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
