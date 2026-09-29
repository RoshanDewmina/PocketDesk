import Foundation

/// The only facts the session Live Activity reads. All of them are things the person can see.
///
/// Renewing the room lease, refreshing relay credentials and restarting ICE on the Mac's side change
/// none of these fields: the phone stays connected and its status does not move. So a renewal can
/// never flicker the Lock Screen, and "Reconnecting" appears only when the phone's own automatic
/// reconnect engages after a live session dropped.
struct SessionSnapshot: Equatable {
    /// A live media session with the Mac.
    var connected = false
    /// The phone's own reconnect is under way after a session that was live.
    var reconnecting = false
    /// While the app holds a live session in the background: when Farside lets go of the Mac.
    var holdEndsAt: Date?
    /// The app is in the background, holding the session or having released it.
    var backgrounded = false
    var route: FarsideSessionAttributes.Route?
    /// Why the session ended, when the model knows.
    var endReason: FarsideSessionAttributes.EndReason?
}

/// Decides when the Live Activity starts, changes and ends. Pure: it holds no ActivityKit types, so
/// every transition is testable without a device.
struct SessionActivityMachine {
    enum Command: Equatable {
        case start(FarsideSessionAttributes.ContentState)
        case update(FarsideSessionAttributes.ContentState)
        case end(FarsideSessionAttributes.EndReason)
    }

    private(set) var hasActivity = false
    private(set) var current: FarsideSessionAttributes.ContentState?
    /// The last route seen. A gap in the statistics never blanks it: only a real change updates.
    private var route: FarsideSessionAttributes.Route?

    /// True when the snapshot would show "Reconnecting" for a session that has an activity. The
    /// controller waits a moment before applying it so a blip never shows.
    func isReconnectingCandidate(_ snapshot: SessionSnapshot) -> Bool {
        hasActivity && !snapshot.connected && snapshot.reconnecting
    }

    mutating func reduce(_ snapshot: SessionSnapshot) -> Command? {
        if snapshot.connected {
            if let seen = snapshot.route { route = seen }
            let desired: FarsideSessionAttributes.ContentState
            if snapshot.backgrounded, let ends = snapshot.holdEndsAt {
                desired = .paused(graceEnds: ends, route: route)
            } else {
                desired = .live(route: route)
            }
            return move(to: desired)
        }
        guard hasActivity else { return nil }
        if snapshot.reconnecting {
            return move(to: .reconnecting(route: route))
        }
        let reason = snapshot.endReason ?? (snapshot.backgrounded ? .timeout : .error)
        hasActivity = false
        current = nil
        route = nil
        return .end(reason)
    }

    private mutating func move(to desired: FarsideSessionAttributes.ContentState) -> Command? {
        if !hasActivity {
            hasActivity = true
            current = desired
            return .start(desired)
        }
        guard desired != current else { return nil }
        current = desired
        return .update(desired)
    }

    /// The activity was ended from outside (the person swiped it away, or the intent ended it).
    mutating func activityWasEnded() {
        hasActivity = false
        current = nil
        route = nil
    }

    /// When the system should treat the activity's content as out of date if nothing refreshes it.
    /// A lost end push, or an app that died, then shows "Session ended?" instead of a frozen "Live".
    static func staleDate(for state: FarsideSessionAttributes.ContentState, now: Date) -> Date? {
        switch state.phase {
        case .live: now.addingTimeInterval(180)
        case .paused: (state.graceEndsAt ?? now).addingTimeInterval(5)
        case .reconnecting: now.addingTimeInterval(120)
        case .ended: nil
        }
    }

    /// How often the app refreshes the stale date of a state that has no end of its own.
    static let keepAlive: TimeInterval = 60
}
