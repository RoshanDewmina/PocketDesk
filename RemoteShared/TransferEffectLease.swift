import Foundation

/// One immutable admission. Default leases preserve effect-fenced admission reads; receive
/// budget leases opt into quick reads/closure while settlement still fences admitted effects.
/// Never wait for a main-actor callback inside an effect.
final class TransferEffectLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let effectLock = NSLock()
    private let nonblockingAdmission: Bool
    private var active = true
    init(nonblockingAdmission: Bool = false) { self.nonblockingAdmission = nonblockingAdmission }
    private var admissionIsActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var isActive: Bool {
        if nonblockingAdmission { return admissionIsActive }
        effectLock.lock(); defer { effectLock.unlock() }
        return admissionIsActive
    }
    func closeAdmission() { lock.lock(); active = false; lock.unlock() }
    /// May block. Receive retirement calls this on the serial disk queue after admission closes.
    func retire() {
        effectLock.lock(); defer { effectLock.unlock() }
        closeAdmission()
    }
    func performIfActive<T>(_ effect: () throws -> T) rethrows -> T? {
        effectLock.lock(); defer { effectLock.unlock() }
        // This check is the effect's admission point. A later close cannot undo an admitted
        // publication, so settlement must wait for effectLock before reporting completion.
        guard admissionIsActive else { return nil }
        return try effect()
    }
}
