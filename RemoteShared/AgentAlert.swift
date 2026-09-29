import Foundation

/// Which kind of coding agent asked for the person. A fixed list on purpose: the alert path carries
/// no free text at all, so an agent that is compromised, or steered by an injected prompt, can never
/// put its own words on a person's lock screen or into a spoken reply.
///
/// Names are descriptive, as an AI coding tool is commonly called. Farside ships no product logos or
/// launchers for them, and stays a generic Mac mirror.
enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case cursor
    case other

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .other: "An agent"
        }
    }

    /// The generic name shown when the person turned "Show agent name" off.
    static let genericName = AgentKind.other.displayName

    /// Maps a name in an alert back onto the fixed list. Anything unfamiliar is "An agent", so an
    /// unexpected string is never echoed to the screen.
    init(displayName: String) {
        let folded = displayName.trimmingCharacters(in: .whitespaces).lowercased()
        self = Self.allCases.first { $0 != .other && $0.displayName.lowercased() == folded } ?? .other
    }

    /// Parses the wire spelling, `claude_code` and friends. Unknown spellings are `other`.
    init(wire: String?) {
        self = wire.flatMap(AgentKind.init(rawValue:)) ?? .other
    }
}

/// What the agent's hook reported. Blocking events only for 1.0: an agent finishing, or sitting
/// idle, are separate opt-ins that arrive later.
enum AgentAlertEvent: String, Sendable {
    case needsUser = "needs_user"
}
