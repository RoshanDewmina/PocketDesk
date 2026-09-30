import Foundation

/// One immutable admission. Retirement linearizes with a bounded irreversible effect.
/// Never enter from a registry lock or wait for a main-actor callback inside the effect.
final class TransferEffectLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func retire() { lock.lock(); active = false; lock.unlock() }
    func performIfActive<T>(_ effect: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        return try effect()
    }
}
