import Foundation
import CoreGraphics
import ScreenCaptureKit

/// The same lock owns admission, queued generations, pressed state and the actual posting call.
/// Main may revoke synchronously; a queued callback never owns a cached permission Boolean.
final class HostInputExecutor: @unchecked Sendable {
    struct Receipt {
        let outcome: RemoteInputOutcome
        let generation: UInt64
        let point: CGPoint
        let externalHold: String?
        let enabled: Bool
        let startedMs: Double
        let endedMs: Double
    }
    struct Admitted { let action: RemoteAction; let upgraded: Bool; let expires: TimeInterval }
    struct BatchReceipt {
        let context: InputCausalEnvelope
        let results: [(RemoteAction, Receipt)]
        let generation: UInt64
        let applied: UInt64
        let failed: Bool
        let intervention: Bool
    }
    private var causalContext: InputCausalEnvelope?
    private var ledger = InputAppliedLedger()
    private var pointerAnchor: CGPoint?
    func beginCausalContext(_ context: InputCausalEnvelope) {
        withAuthority {
            if causalContext != nil { invalidateLocked() }
            causalContext = context; ledger.reset()
            let ticket = generation
            // Reserve the handoff in the same FIFO as already admitted legacy posts. No main
            // queue drain: those posts establish the anchor before any upgraded checkpoint.
            queue.async { [self] in
                withAuthority {
                    guard ticket == generation, causalContext?.nonce == context.nonce,
                          causalContext?.anchor == context.anchor, causalContext?.epoch == context.epoch else { return }
                    pointerAnchor = driver.nextPointerBase(now: clock())
                }
            }
        }
    }
    func endCausalContext() {
        withAuthority { invalidateLocked(); causalContext = nil; pointerAnchor = nil; ledger.reset() }
    }
    var appliedOrdinal: UInt64 { withAuthority { ledger.applied } }
    /// Cleanup cancels unposted motion up to the reliable release checkpoint; late portions
    /// cannot move a pointer after its hold has been released.
    func discardCausalPrefix(_ context: InputCausalEnvelope) {
        withAuthority { ledger.discard(through: context.applied) }
    }
    @discardableResult
    func submitCausal(_ context: InputCausalEnvelope, steps: [Admitted], semantic: Admitted?, preparation: DispatchGroup? = nil,
                      routeAuthority: @escaping (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome,
                      completion: @escaping (BatchReceipt) -> Void) -> Bool {
        let contextBytes = (try? JSONEncoder().encode(context).count) ?? Self.maximumQueuedBytes + 1
        let semanticBytes = semantic.map { (try? JSONEncoder().encode($0.action).count) ?? Self.maximumQueuedBytes + 1 } ?? 0
        let bytes = contextBytes + semanticBytes
        lock.lock()
        guard queued < Self.maximumQueued, bytes <= Self.maximumQueuedBytes - queuedBytes else { lock.unlock(); return false }
        let ticket = generation; queued += 1; queuedBytes += bytes
        if let semantic { reserveHold(semantic.action, ticket: ticket) }
        lock.unlock()
        queue.async { [self] in
            let prepared = preparation?.wait(timeout: .now() + 1) != .timedOut
            let receipt: BatchReceipt = withAuthority {
                queued -= 1; queuedBytes -= bytes
                defer { finishReservation(semantic?.action, ticket: ticket) }
                var results: [(RemoteAction, Receipt)] = []
                var failed = false, intervention = false
                let current = causalContext
                if !prepared || ticket != generation || current?.nonce != context.nonce || current?.anchor != context.anchor || current?.epoch != context.epoch {
                    failed = true
                } else if !driver.pointerMatchesCausalAnchor(pointerAnchor, now: clock()) {
                    failed = true; intervention = true
                } else {
                    do {
                        let missing = try ledger.missing(from: context)
                        for segment in missing {
                            guard let index = context.segments.firstIndex(where: { $0.ordinal == segment.ordinal }), steps.indices.contains(index) else { throw RemoteError.stale }
                            let admitted = steps[index]
                            let result = post(admitted, ticket: ticket, routeAuthority: routeAuthority)
                            results.append((segment.action, result))
                            guard result.outcome.accepted else { throw RemoteError.stale }
                            try ledger.recordPosted(segment.ordinal)
                            pointerAnchor = driver.lastPoint
                        }
                        if let semantic {
                            let result = post(semantic, ticket: ticket, routeAuthority: routeAuthority)
                            results.append((semantic.action, result))
                        }
                    } catch { failed = true }
                }
                return BatchReceipt(context: context, results: results, generation: ticket,
                                    applied: ledger.applied, failed: failed, intervention: intervention)
            }
            DispatchQueue.main.async { completion(receipt) }
        }
        return true
    }
    private func post(_ admitted: Admitted, ticket: UInt64,
                      routeAuthority: (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome) -> Receipt {
        let start = MachClock.nowMs(), now = clock()
        var outcome = RemoteInputOutcome(textRequestID: admitted.action.action == "text" ? admitted.action.key : nil)
        if ticket == generation, now < admitted.expires, driver.enabled, !lease.isExpired(at: now) {
            outcome = routeAuthority { [self] in driver.handle(admitted.action, upgraded: admitted.upgraded, now: now) }
            lease.record(action: admitted.action.action, accepted: outcome.accepted, at: now)
            if outcome.holdEvent == .ended { lease.cancel() }
        }
        return Receipt(outcome: outcome, generation: ticket, point: driver.lastPoint,
                       externalHold: driver.externalHoldID, enabled: driver.enabled,
                       startedMs: start, endedMs: MachClock.nowMs())
    }
    private let lock = NSRecursiveLock()
    private let queue: DispatchQueue
    private let driver: RemoteInputDriver
    private let clock: () -> TimeInterval
    private var generation: UInt64 = 0
    private var queued = 0
    private var queuedBytes = 0
    private var pendingHolds: [String: Int] = [:]
    private func invalidateLocked() { generation &+= 1; pendingHolds.removeAll() }
    private func reserveHold(_ action: RemoteAction, ticket: UInt64) {
        if ticket == generation, action.action == "dragDown", let hold = action.interaction?.hold {
            pendingHolds[hold, default: 0] += 1
        }
    }
    private func finishReservation(_ action: RemoteAction?, ticket: UInt64) {
        if ticket == generation, let action, action.action == "dragDown", let hold = action.interaction?.hold {
            let count = pendingHolds[hold, default: 0] - 1
            pendingHolds[hold] = count > 0 ? count : nil
        }
    }
    func releaseScope(for action: RemoteAction) -> String? {
        withAuthority {
            if let actual = driver.externalHoldID { return actual }
            if let requested = action.interaction?.hold, pendingHolds[requested] != nil { return requested }
            return pendingHolds.keys.sorted().first
        }
    }
    private var lease = RemoteInputLease()
    static let maximumQueued = 128
    static let maximumQueuedBytes = 256 * 1024

    init(driver: RemoteInputDriver = RemoteInputDriver(isTrusted: { true }),
         queue: DispatchQueue = DispatchQueue(label: "farside.input.post", qos: .userInteractive),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver; self.queue = queue; self.clock = clock
    }
    @discardableResult
    func withAuthority<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var enabled: Bool {
        get { withAuthority { driver.enabled } }
        set { withAuthority {
            let wasEnabled = driver.enabled
            if wasEnabled && !newValue { invalidateLocked() }
            driver.enabled = newValue
            if !wasEnabled && newValue, causalContext != nil { pointerAnchor = driver.nextPointerBase(now: clock()) }
        } }
    }
    var displayBounds: CGRect? { withAuthority { driver.displayBounds } }
    var held: Bool { withAuthority { driver.held } }
    var holdID: UInt64? { withAuthority { driver.holdID } }
    var externalHoldID: String? { withAuthority { driver.externalHoldID } }
    var lastPoint: CGPoint { withAuthority { driver.lastPoint } }
    var currentGeneration: UInt64 { withAuthority { generation } }
    func accepts(_ receipt: Receipt) -> Bool { withAuthority { receipt.generation == generation } }
    func invalidateQueued() { withAuthority { invalidateLocked() } }
    func configure(_ filter: SCContentFilter) { withAuthority { invalidateLocked(); driver.configure(filter); lease.cancel() } }
    func configure(bounds: CGRect?) { withAuthority { invalidateLocked(); driver.configure(bounds: bounds); lease.cancel() } }
    func configure(displays: [CGRect]) { withAuthority { invalidateLocked(); driver.configure(displays: displays); lease.cancel() } }
    @discardableResult
    func release() -> Bool { withAuthority { invalidateLocked(); let result = driver.release(); if result { lease.cancel() }; return result } }
    func resetNativeSequence() { withAuthority { invalidateLocked(); driver.resetNativeSequence() } }
    func expireMomentum() { withAuthority { driver.expireMomentum(now: clock()) } }
    func nextPointerBase(now: TimeInterval) -> CGPoint? { withAuthority { driver.nextPointerBase(now: now) } }
    func changeLeaseDuration(to duration: TimeInterval, at now: TimeInterval) { withAuthority { lease.changeDuration(to: duration, at: now) } }
    func leaseExpired(at now: TimeInterval) -> Bool { withAuthority { lease.isExpired(at: now) } }
    func cancelLease() { withAuthority { lease.cancel() } }

    /// `routeAuthority` must retain the peer's route/lifetime fence through the supplied posting
    /// operation. It must not read actor-owned coordinator or UI state from this queue.
    @discardableResult
    func submit(_ action: RemoteAction, upgraded: Bool, expires: TimeInterval, expectedGeneration: UInt64? = nil, preparation: DispatchGroup? = nil,
                routeAuthority: @escaping (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome,
                completion: @escaping (Receipt) -> Void) -> Bool {
        let bytes = (try? JSONEncoder().encode(action).count) ?? Self.maximumQueuedBytes + 1
        lock.lock()
        guard queued < Self.maximumQueued, bytes <= Self.maximumQueuedBytes - queuedBytes else { lock.unlock(); return false }
        let ticket = expectedGeneration ?? generation
        queued += 1; queuedBytes += bytes
        reserveHold(action, ticket: ticket)
        lock.unlock()
        queue.async { [self] in
            let prepared = preparation?.wait(timeout: .now() + 1) != .timedOut
            let receipt: Receipt = withAuthority {
                queued -= 1; queuedBytes -= bytes
                defer { finishReservation(action, ticket: ticket) }
                let start = MachClock.nowMs(), now = clock()
                var outcome = RemoteInputOutcome(textRequestID: action.action == "text" ? action.key : nil)
                if prepared, ticket == generation, now < expires, driver.enabled, !lease.isExpired(at: now) {
                    outcome = routeAuthority { [self] in driver.handle(action, upgraded: upgraded, now: now) }
                    lease.record(action: action.action, accepted: outcome.accepted, at: now)
                    if outcome.holdEvent == .ended { lease.cancel() }
                }
                return Receipt(outcome: outcome, generation: ticket, point: driver.lastPoint,
                               externalHold: driver.externalHoldID, enabled: driver.enabled,
                               startedMs: start, endedMs: MachClock.nowMs())
            }
            DispatchQueue.main.async { completion(receipt) }
        }
        return true
    }

    /// Harness-only callers retain their existing main-thread AppKit fence. Production posts
    /// through submit; both paths use identical authority and pressed-state ownership.
    func handle(_ action: RemoteAction, upgraded: Bool, now: TimeInterval, pointerSnapshot: CGPoint? = nil) -> RemoteInputOutcome {
        withAuthority {
            let outcome = driver.handle(action, upgraded: upgraded, now: now, pointerSnapshot: pointerSnapshot)
            lease.record(action: action.action, accepted: outcome.accepted, at: now)
            if outcome.holdEvent == .ended { lease.cancel() }
            return outcome
        }
    }
    func drain() { queue.sync {} }
}
