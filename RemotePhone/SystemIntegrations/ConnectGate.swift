import Foundation

/// The one path every Connect takes: the Home button, the Connect prompt behind the widget and links,
/// and Siri or Shortcuts. Pending server-data removal is checked first, then the optional owner check
/// (Settings → Security), then Local Network priming, then Anywhere's token, and only then does the
/// coordinator start.
@MainActor
enum ConnectGate {
    enum Decision: Equatable {
        case proceed
        case notPaired
        case alreadyUnderWay
        /// Server-data removal is pending or needs recovery: show Server Data instead of connecting.
        case serverData
    }

    /// - Parameter restartsRunning: the Home button may restart an attempt; system requests never do.
    nonisolated static func decide(paired: Bool, connected: Bool, running: Bool, restartsRunning: Bool,
                       removalBlocked: Bool) -> Decision {
        guard paired else { return .notPaired }
        guard !connected, restartsRunning || !running else { return .alreadyUnderWay }
        return removalBlocked ? .serverData : .proceed
    }

    /// The owner check runs only for a Connect that will start something, so a live session is never
    /// interrupted and nothing already under way is asked about again.
    nonisolated static func asksOwner(_ decision: Decision) -> Bool { decision == .proceed }

    static func removalBlocked(_ access: AnywhereAccess) -> Bool {
        access.removalPending || access.localCleanupPending || access.removalRecoveryRequired
    }

    @discardableResult
    static func connect(model: PhoneRemoteModel, onboarding: OnboardingFlow, restartsRunning: Bool, mode: SessionMode = .picture,
                        access: AnywhereAccess = .shared, owner: DeviceOwnerGate? = nil,
                        showServerData: @escaping () -> Void) -> Decision {
        let owner = owner ?? .live
        let connection = model.connection
        let decision = decide(paired: connection.invitation != nil, connected: connection.connected,
                              running: connection.isRunning, restartsRunning: restartsRunning,
                              removalBlocked: removalBlocked(access))
        switch decision {
        case .serverData:
            showServerData()
        case .proceed:
            model.error = ""
            let start = {
                model.prepareConnection(mode: mode)
                onboarding.beforeConnect {
                    Task { @MainActor in
                        // Only waits when this phone has Anywhere and its token is due; never more than a few seconds.
                        if mode == .picture { await access.prepareForConnection() }
                        guard access.phoneConnectionAllowed else { showServerData(); return }
                        connection.start()
                    }
                }
            }
            guard asksOwner(decision), owner.preferences.requireOwnerToConnect else { start(); return decision }
            Task { @MainActor in
                let purpose = DeviceOwnerGate.Purpose.connect(macName: connection.invitation?.name)
                let outcome = await owner.check(purpose)
                guard outcome.allows else {
                    model.error = DeviceOwnerGate.message(for: outcome, purpose: purpose,
                                                          biometryName: owner.authenticator.biometryName) ?? ""
                    return
                }
                // Another path may have connected while the check was on screen.
                guard decide(paired: connection.invitation != nil, connected: connection.connected,
                             running: connection.isRunning, restartsRunning: restartsRunning,
                             removalBlocked: removalBlocked(access)) == .proceed else { return }
                start()
            }
        case .notPaired, .alreadyUnderWay:
            break
        }
        return decision
    }
}
