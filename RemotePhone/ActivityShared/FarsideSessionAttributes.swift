import ActivityKit
import Foundation

/// The session Live Activity's data. Compiled into the app and the widget extension.
///
/// The wire format is deliberately plain so a service could build an update by hand: string raw
/// values and integer Unix seconds only, no payload-carrying enums and no `Date`. ActivityKit
/// decodes pushed state with default `Codable` strategies, so a custom encoder would silently fail.
/// Nothing here can carry screen content, prompt text, file names or a latency figure.
struct FarsideSessionAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case live, paused, reconnecting, ended
    }

    enum Route: String, Codable, Hashable {
        case local, direct, relay
    }

    enum EndReason: String, Codable, Hashable {
        case user, timeout, macStopped, error
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// While paused: when Farside lets go of the Mac. Unix seconds.
        var graceEndsAtUnix: Int?
        var route: Route?
        var endedReason: EndReason?
    }

    /// Opaque, stable per pairing. Never the room id or a name.
    let macId: String
    /// What the views call the Mac. "Your Mac" unless the person opted in to showing the name.
    let macLabel: String
    let sessionId: String
    let startedAtUnix: Int
    /// True for the labelled sample the Settings preview button starts. Absent for real sessions.
    let preview: Bool?

    var isPreview: Bool { preview == true }
    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(startedAtUnix)) }
}

extension FarsideSessionAttributes.ContentState {
    var graceEndsAt: Date? {
        graceEndsAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func live(route: FarsideSessionAttributes.Route? = nil) -> Self {
        Self(phase: .live, graceEndsAtUnix: nil, route: route, endedReason: nil)
    }

    static func paused(graceEnds: Date, route: FarsideSessionAttributes.Route? = nil) -> Self {
        Self(phase: .paused, graceEndsAtUnix: Int(graceEnds.timeIntervalSince1970.rounded()), route: route, endedReason: nil)
    }

    static func reconnecting(route: FarsideSessionAttributes.Route? = nil) -> Self {
        Self(phase: .reconnecting, graceEndsAtUnix: nil, route: route, endedReason: nil)
    }

    static func ended(_ reason: FarsideSessionAttributes.EndReason) -> Self {
        Self(phase: .ended, graceEndsAtUnix: nil, route: nil, endedReason: reason)
    }
}

/// The words on every Live Activity surface, in one place so the views and the tests agree.
/// House voice: one deadpan clause, and the meaning always stands alone.
enum SessionActivityCopy {
    static func title(for state: FarsideSessionAttributes.ContentState, stale: Bool = false) -> String {
        if stale { return "Session ended?" }
        switch state.phase {
        case .live: return "Holding your Mac"
        case .paused: return "Mac on hold"
        case .reconnecting: return "Reaching for your Mac"
        case .ended:
            switch state.endedReason ?? .user {
            case .user: return "Session ended"
            case .timeout: return "Let go of your Mac"
            case .macStopped: return "Sharing stopped"
            case .error: return "Session ended"
            }
        }
    }

    /// The second line. `macLabel` is "Your Mac" unless the person opted in to showing the name.
    static func line(for state: FarsideSessionAttributes.ContentState, macLabel: String, stale: Bool = false) -> String {
        if stale { return "Farside stopped updating. Open it to check." }
        switch state.phase {
        case .live:
            return [macLabel, state.route.map(routeWord)].compactMap { $0 }.joined(separator: " · ")
        case .paused:
            return "Farside lets go soon. Come back and it never happened."
        case .reconnecting:
            return "Hold on. It is a long way."
        case .ended:
            switch state.endedReason ?? .user {
            case .user: return "\(macLabel) has its desk back."
            case .timeout: return "You were away, so Farside let go. Tap to reconnect."
            case .macStopped: return "It was stopped at the Mac."
            case .error: return "Something went wrong. Nothing was left open."
            }
        }
    }

    /// The second line in the Dynamic Island, which has room for two short lines: only the paused state
    /// needs a shorter one, because its countdown and title already say that Farside lets go soon.
    static func islandLine(for state: FarsideSessionAttributes.ContentState, macLabel: String, stale: Bool = false) -> String {
        if !stale, state.phase == .paused { return "Come back and it never happened." }
        return line(for: state, macLabel: macLabel, stale: stale)
    }

    static func routeWord(_ route: FarsideSessionAttributes.Route) -> String {
        switch route {
        case .local: "same Wi-Fi"
        case .direct: "direct"
        case .relay: "relayed"
        }
    }

    static func accessibilitySummary(for state: FarsideSessionAttributes.ContentState, stale: Bool = false) -> String {
        if stale { return "Farside. Session may have ended." }
        switch state.phase {
        case .live: return "Farside. Connected to your Mac."
        case .paused: return "Farside. Session on hold. Farside lets go of your Mac soon."
        case .reconnecting: return "Farside. Reconnecting to your Mac."
        case .ended: return "Farside. \(title(for: state))."
        }
    }
}
