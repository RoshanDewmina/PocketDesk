import Foundation

/// Which kind of coding agent asked for the person. A fixed list on purpose: the alert path carries
/// no free text at all, so an agent that is compromised, or steered by an injected prompt, can never
/// put its own words on a person's lock screen or into a spoken reply.
///
/// `displayName` is for the Mac companion's own activity log only. The phone never shows it and
/// no push carries it: phone alerts use fixed generic copy (Guideline 4.5.4, and 4.2.7's generic mirror).
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
