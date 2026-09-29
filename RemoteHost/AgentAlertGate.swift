import Foundation

/// Decides which agent alerts reach the phone. Repeated asks from one agent session are one alert, an
/// agent that asks again after a minute is a new one, and a runaway agent cannot flood a phone: at
/// most six an hour. Pure state with an injected clock, so every rule is testable without waiting.
struct AgentAlertGate {
    struct Limits: Equatable {
        var sessionCooldown: TimeInterval = 60
        var perWindow = 6
        var window: TimeInterval = 3600
        var rememberedSessions = 128
    }

    enum Decision: Equatable {
        case admit
        /// The same agent session already raised this recently.
        case duplicate
        case rateLimited
    }

    var limits = Limits()
    private var lastBySession: [String: Date] = [:]
    private var admitted: [Date] = []

    mutating func decide(sessionHash: String, now: Date) -> Decision {
        prune(now)
        if let last = lastBySession[sessionHash], now.timeIntervalSince(last) < limits.sessionCooldown {
            return .duplicate
        }
        guard admitted.count < limits.perWindow else { return .rateLimited }
        lastBySession[sessionHash] = now
        admitted.append(now)
        return .admit
    }

    private mutating func prune(_ now: Date) {
        admitted.removeAll { now.timeIntervalSince($0) >= limits.window }
        lastBySession = lastBySession.filter { now.timeIntervalSince($0.value) < limits.window }
        if lastBySession.count > limits.rememberedSessions {
            let keep = lastBySession.sorted { $0.value > $1.value }.prefix(limits.rememberedSessions)
            lastBySession = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// What the Mac did with an alert, in the words a hook can act on. Maps to an HTTP status.
enum AgentAlertDisposition: String, Equatable, Sendable {
    /// Told the phone over the live control channel.
    case forwarded
    /// Sent as a push to a phone that has no live session.
    case pushed
    case duplicate
    case rateLimited = "rate_limited"
    /// No phone is paired with this Mac.
    case noPhone = "no_phone"
    /// The phone is not in a session and push delivery is not switched on yet.
    case pushUnavailable = "push_unavailable"
    /// Agent alerts are off on this Mac.
    case disabled
    /// A well-formed event Farside does not raise alerts for.
    case ignored
}

/// How an alert would reach a phone that is not in a session: an APNs push through Farside's service.
/// Nothing implements it yet, so the default says exactly why it cannot.
protocol AgentPushRelay: Sendable {
    func deliver(_ alert: AgentAlert) async -> AgentPushOutcome
}

enum AgentPushOutcome: Equatable, Sendable {
    case sent
    case unavailable(String)
}

/// The push path, stubbed. What is missing is listed in design/SYSTEM-INTEGRATIONS-REPORT.md: an APNs
/// auth key per environment, the service's push registry and `agent_event` relay, the phone's token
/// registration, and the Mac's `agent_event` message on its host socket.
struct UnconfiguredAgentPushRelay: AgentPushRelay {
    func deliver(_ alert: AgentAlert) async -> AgentPushOutcome {
        .unavailable("Push delivery is not configured: no APNs key or push service yet.")
    }
}
