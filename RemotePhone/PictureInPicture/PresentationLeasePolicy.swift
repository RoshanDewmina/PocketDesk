import Foundation

/// Authenticated model facts only. Neither a room name nor OS PiP capability is media authority.
struct PresentationLeasePolicy {
    static func admission(identity: VideoPresentationIdentity?, routeDeadline: TimeInterval?,
                          captureHealthAt: TimeInterval, healthy: Bool, picture: Bool,
                          trackPresent: Bool, blocked: Bool, now: TimeInterval) -> VideoPresentationAdmission? {
        guard let identity, let routeDeadline, healthy, picture, trackPresent, !blocked,
              identity.geometryEpoch > 0, captureHealthAt > 0,
              now.isFinite, captureHealthAt.isFinite, routeDeadline.isFinite,
              captureHealthAt <= now else { return nil }
        let next = VideoPresentationAdmission(identity: identity, validUntil: min(routeDeadline, captureHealthAt + 2))
        return next.permits(at: now) ? next : nil
    }
    static func mayContinueBackground(state: LivePiPPolicy.State, admission: VideoPresentationAdmission?,
                                      viewOnlyConfirmed: Bool, now: TimeInterval) -> Bool {
        state == .active && viewOnlyConfirmed && admission?.permits(at: now) == true
    }
}
