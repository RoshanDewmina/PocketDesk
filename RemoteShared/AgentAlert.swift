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

/// Fixed event vocabulary. Job outcomes come only from explicit local exit-status reports.
enum AgentAlertEvent: String, CaseIterable, Sendable {
    case needsUser = "needs_user"
    case completed
    case failed

    var isAttention: Bool { self == .needsUser }
    var titleKey: String {
        switch self {
        case .needsUser: "AGENT_NEEDS_YOU_TITLE"
        case .completed: "AGENT_COMPLETED_TITLE"
        case .failed: "AGENT_FAILED_TITLE"
        }
    }
    var bodyKey: String {
        switch self {
        case .needsUser: "AGENT_NEEDS_YOU_BODY"
        case .completed: "AGENT_COMPLETED_BODY"
        case .failed: "AGENT_FAILED_BODY"
        }
    }
    var genericTitle: String {
        switch self {
        case .needsUser: "A task on your Mac needs you"
        case .completed: "A task on your Mac finished"
        case .failed: "A task on your Mac failed"
        }
    }
    var genericBody: String {
        switch self {
        case .needsUser: "Stuck on something only a human can click."
        case .completed: "Open your Mac to check the result."
        case .failed: "Open your Mac to check what happened."
        }
    }
}
