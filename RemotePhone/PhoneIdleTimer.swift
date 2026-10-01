import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Foreground UI ownership, independent of controller leases and frame cadence.
/// Each producer releases only itself; transfer completion cannot dim a live session.
@MainActor
final class PhoneIdleTimer {
    enum Owner: Hashable { case session, transfer(UUID) }
    #if canImport(UIKit)
    static let shared = PhoneIdleTimer { UIApplication.shared.isIdleTimerDisabled = $0 }
    #endif
    private let apply: (Bool) -> Void
    private var owners: Set<Owner> = []
    private(set) var foreground = false
    private(set) var isDisabled = false

    init(apply: @escaping (Bool) -> Void) { self.apply = apply }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { owners.removeAll() }
        update()
    }
    func set(_ owner: Owner, active: Bool) {
        if active && foreground { owners.insert(owner) } else { owners.remove(owner) }
        update()
    }
    /// Includes view-only, audio and Couch: no controller token or decoded frame required.
    /// Caller supplies authenticated transport state; this never creates authority.
    func updateSession(authenticated: Bool, paused: Bool, concealed: Bool) {
        set(.session, active: authenticated && !paused && !concealed)
    }
    func endSession() { set(.session, active: false) }
    private func update() {
        let next = foreground && !owners.isEmpty
        guard next != isDisabled else { return }
        isDisabled = next
        apply(next)
    }
}
