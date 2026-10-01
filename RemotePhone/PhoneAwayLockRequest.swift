import Foundation

/// A lock request is neither a lock receipt nor a capability. A current authenticated host
/// status may report locked; timeout still requires truthful unconfirmed copy.
struct PhoneAwayLockRequest: Equatable {
    let hostKey: String
    let session: UUID
    let epoch: UInt64
    let sentAt: TimeInterval
    static let timeout: TimeInterval = 5
    func matches(hostKey: String?, session: UUID, epoch: UInt64, at now: TimeInterval) -> Bool {
        hostKey == self.hostKey && session == self.session && epoch == self.epoch && epoch > 0 &&
            now.isFinite && sentAt.isFinite && now >= sentAt && now - sentAt <= Self.timeout
    }
}
