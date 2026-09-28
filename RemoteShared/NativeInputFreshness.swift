import Foundation

/// Host-clock-only admission for native actions. A token is bound to one geometry/session epoch.
struct NativeInputFreshness {
    enum Admission: Equatable {
        case legacy
        case upgraded
        case terminate
    }

    private struct Issued {
        let value: String
        let epoch: UInt64
        let expires: TimeInterval
    }

    private(set) var upgraded = false
    private var issued: [Issued] = []
    private let lifetime: TimeInterval = 1
    private let limit = 8

    mutating func invalidate() {
        upgraded = false
        issued.removeAll()
    }

    mutating func expireTokens() {
        issued.removeAll()
    }

    /// Mouse-up is cleanup: an expired capability token must not trap a held button.
    /// Once a peer upgrades, only its exact active hold in the current epoch can release.
    func acceptsRelease(_ action: RemoteAction, epoch: UInt64, activeHold: String?) -> Bool {
        guard action.action == "release" else { return false }
        if !upgraded { return action.interaction == nil }
        guard action.epoch == epoch,
              let activeHold,
              let interaction = action.interaction,
              interaction.version == 1,
              interaction.hold == activeHold
        else { return false }
        return true
    }

    /// A delayed host cleanup notice may arrive after the phone starts another hold.
    /// Omit upgraded notices without a captured identity; the phone cannot scope them.
    func releaseNotice(epoch: UInt64, releasedHold: String?) -> RemoteAction? {
        if !upgraded { return RemoteAction(action: "release", epoch: epoch) }
        guard let releasedHold else { return nil }
        return RemoteAction(
            action: "release", epoch: epoch,
            interaction: NativeInteraction(hold: releasedHold)
        )
    }

    func rejectedDragDownNotice(_ action: RemoteAction, activeHold: String?) -> RemoteAction? {
        guard upgraded, action.action == "dragDown",
              let attemptedHold = action.interaction?.hold,
              attemptedHold != activeHold else { return nil }
        return releaseNotice(epoch: action.epoch, releasedHold: attemptedHold)
    }

    mutating func capability(epoch: UInt64, now: TimeInterval, doubleClickInterval: Double) -> NativeInteraction {
        issued.removeAll { $0.epoch != epoch || now >= $0.expires }
        let token = UUID().uuidString
        issued.append(Issued(value: token, epoch: epoch, expires: now + lifetime))
        if issued.count > limit { issued.removeFirst(issued.count - limit) }
        return NativeInteraction(token: token, doubleClickInterval: doubleClickInterval)
    }

    mutating func admit(_ action: RemoteAction, epoch: UInt64, now: TimeInterval) -> Admission {
        guard action.epoch == epoch else { return .terminate }
        guard let interaction = action.interaction else {
            return upgraded ? .terminate : .legacy
        }
        guard interaction.version == 1, let token = interaction.token,
              issued.contains(where: { $0.value == token && $0.epoch == epoch && now < $0.expires })
        else { return .terminate }
        upgraded = true
        return .upgraded
    }
}
