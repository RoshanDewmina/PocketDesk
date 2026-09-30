import Foundation
import ApplicationServices

/// The time an Accessibility query may take in total. AX messaging timeouts apply per call, so every
/// call takes whatever remains, and the work stops asking once it has run out.
final class HostAXBudget: @unchecked Sendable {
    static let perCall: TimeInterval = 0.12

    let deadline: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(total: TimeInterval, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        deadline = clock() + max(0, total)
    }

    var remaining: TimeInterval { max(0, deadline - clock()) }
    var isExhausted: Bool { isCancelled || remaining <= 0.005 }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// The messaging timeout for the next AX call, or nil when none may be made.
    var nextCallTimeout: Float? {
        guard !isExhausted else { return nil }
        return Float(min(Self.perCall, remaining))
    }

    /// Applies the next call's timeout to an element. False means stop.
    func arm(_ element: AXUIElement) -> Bool {
        guard let timeout = nextCallTimeout else { return false }
        return AXUIElementSetMessagingTimeout(element, timeout) == .success
    }
}

/// One background lane for Accessibility queries, off the capture, input and main threads. At most one
/// query runs at a time and a new one is dropped rather than queued behind a slow app. The caller hears
/// back by the deadline: a result that arrives later is discarded even though the AX call itself cannot
/// be interrupted, and the lane stays busy until that call really returns.
final class HostAXBroker: @unchecked Sendable {
    static let shared = HostAXBroker()
    static let defaultBudget: TimeInterval = 0.25

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var busy = false
    private let clock: () -> TimeInterval

    init(label: String = "com.roshan.farside.ax-broker",
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.clock = clock
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    func run<T: Sendable>(budget total: TimeInterval = defaultBudget,
                          _ work: @escaping @Sendable (HostAXBudget) -> T?) async -> T? {
        guard total.isFinite, total > 0, claim() else { return nil }
        let budget = HostAXBudget(total: total, clock: clock)
        let reply = ReplyOnce<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                reply.install(continuation)
                queue.async { [self] in
                    let result = budget.isExhausted ? nil : work(budget)
                    release()
                    reply.resume(budget.isCancelled || budget.remaining <= 0 ? nil : result)
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + total) {
                    budget.cancel()
                    reply.resume(nil)
                }
            }
        } onCancel: {
            budget.cancel()
            reply.resume(nil)
        }
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    private func release() { lock.lock(); busy = false; lock.unlock() }

    private final class ReplyOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var done = false
        private var early: T??

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ value: T?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            guard let continuation else {
                early = .some(value)
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }
}
