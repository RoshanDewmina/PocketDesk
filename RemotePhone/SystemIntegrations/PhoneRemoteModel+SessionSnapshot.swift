import Foundation

extension SessionSnapshot {
    /// The snapshot for a coordinator state. Pure, so the exact status strings the coordinator emits
    /// can be fed in by tests.
    ///
    /// "Reconnecting" means the phone's own automatic reconnect is under way: the coordinator is still
    /// running, not connected, and saying so with a busy status (or the model is resuming after a
    /// background hold). A stopped coordinator is not reconnecting, whatever its last status says.
    static func derive(connected: Bool, running: Bool, status: String, resumeState: ResumeState,
                       holdEndsAt: Date?, routeName: String?, endReason: FarsideSessionAttributes.EndReason?) -> SessionSnapshot {
        let route: FarsideSessionAttributes.Route?
        switch routeName {
        case "Direct": route = .direct
        case "Relay": route = .relay
        default: route = nil
        }
        let busy = MacStatus(status).tone == .busy
        return SessionSnapshot(
            connected: connected,
            reconnecting: !connected && running && (busy || resumeState == .reconnecting),
            holdEndsAt: holdEndsAt,
            backgrounded: resumeState == .backgrounded,
            route: route,
            endReason: endReason)
    }
}

extension PhoneRemoteModel {
    /// What the session Live Activity may know. Built only from what the person can see: whether the
    /// session is live, whether the phone's own reconnect is under way, the background hold, a coarse
    /// route word, and why it ended. Lease renewals, relay credential refreshes and ICE restarts touch
    /// none of it, so they never move the Lock Screen.
    var sessionSnapshot: SessionSnapshot {
        SessionSnapshot.derive(connected: connection.connected, running: connection.isRunning,
                               status: connection.status, resumeState: resumeState,
                               holdEndsAt: backgroundHoldEndsAt, routeName: link?.route,
                               endReason: sessionEndReason)
    }
}
