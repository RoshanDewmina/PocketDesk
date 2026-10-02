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
    static let couchBurstDisabledDefaultsKey = "couchInputBurstCoalescingDisabled"
    private let coalesceCouchMotion: () -> Bool
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
                      traceArrivalMs: Double? = nil,
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
                        let missingSteps = try missing.map { segment -> Admitted in
                            guard let index = context.segments.firstIndex(where: { $0.ordinal == segment.ordinal }), steps.indices.contains(index) else { throw RemoteError.stale }
                            let step = steps[index]
                            // Coalescing must use the admitted segment's same motion and hold.
                            guard step.action.action == segment.action.action, step.action.x == segment.action.x,
                                  step.action.y == segment.action.y, step.action.interaction == segment.action.interaction,
                                  step.action.modifiers == segment.action.modifiers, step.action.pencil == segment.action.pencil else { throw RemoteError.stale }
                            return step
                        }
                        if semantic == nil, coalesceCouchMotion(), missingSteps.allSatisfy(\.upgraded),
                           let merged = driver.coalescedCouchMotion(missingSteps.map(\.action), now: clock()),
                           let expires = missingSteps.map(\.expires).min() {
                            let result = post(Admitted(action: merged.action, upgraded: true, expires: expires), ticket: ticket,
                                              routeAuthority: routeAuthority, pointerSnapshot: merged.base)
                            InputCadenceTrace.posted(context, ordinal: missing.last!.ordinal, coalesced: missing.count,
                                startedMs: result.startedMs, endedMs: result.endedMs, accepted: result.outcome.accepted, arrivalMs: traceArrivalMs)
                            results.append((merged.action, result))
                            guard result.outcome.accepted else { throw RemoteError.stale }
                            for segment in missing { try ledger.recordPosted(segment.ordinal) }
                            pointerAnchor = driver.lastPoint
                        } else {
                            for (segment, admitted) in zip(missing, missingSteps) {
                                let result = post(admitted, ticket: ticket, routeAuthority: routeAuthority)
                                InputCadenceTrace.posted(context, ordinal: segment.ordinal, coalesced: 1,
                                    startedMs: result.startedMs, endedMs: result.endedMs, accepted: result.outcome.accepted, arrivalMs: traceArrivalMs)
                                results.append((segment.action, result))
                                guard result.outcome.accepted else { throw RemoteError.stale }
                                try ledger.recordPosted(segment.ordinal)
                                pointerAnchor = driver.lastPoint
                            }
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
                      routeAuthority: @escaping (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome,
                      pointerSnapshot: CGPoint? = nil) -> Receipt {
        let start = MachClock.nowMs(), now = clock()
        var outcome = RemoteInputOutcome(textRequestID: admitted.action.action == "text" ? admitted.action.key : nil)
        if ticket == generation, now < admitted.expires, driver.enabled, !lease.isExpired(at: now) {
            outcome = routeAuthority { [self] in driver.handle(admitted.action, upgraded: admitted.upgraded, now: now, pointerSnapshot: pointerSnapshot) }
            lease.record(action: admitted.action.action, accepted: outcome.accepted, at: now)
            if outcome.holdEvent == .ended { lease.cancel() }
            coastIfStarted(routeAuthority)
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

    /// The Mac-run scroll coast: a 120 Hz timer on the posting queue, under the same lock as every
    /// other post. Each step is posted through the route authority the `momentumBegan` arrived with
    /// and is subject to the same revocation as a queued post: a new generation (control off, new
    /// geometry, release), a disabled driver or an expired lease ends the coast with its end event.
    /// The driver itself ends it when any other input lands.
    private var coastTimer: DispatchSourceTimer?
    private var coastGeneration: UInt64 = 0
    private var coastRoute: ((@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome)?
    private func coastIfStarted(_ routeAuthority: @escaping (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome) {
        guard driver.isCoasting else { return }
        // A new coast always takes the route and generation of the post that started it, even
        // when it begins inside the previous coast's last tick.
        coastGeneration = generation
        coastRoute = routeAuthority
        guard coastTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + RemoteInputDriver.hostMomentumInterval,
                       repeating: RemoteInputDriver.hostMomentumInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.withAuthority { self.stepCoast() }
        }
        coastTimer = timer
        timer.resume()
    }
    private func stepCoast() {
        guard let route = coastRoute else { stopCoast(); return }
        let now = clock()
        let revoked = generation != coastGeneration || !driver.enabled || lease.isExpired(at: now)
        var routed = false
        let running = route { [self] in
            routed = true
            if revoked { driver.endHostMomentum(); return RemoteInputOutcome() }
            return RemoteInputOutcome(accepted: driver.stepHostMomentum(now: now))
        }.accepted
        // A closed route posts nothing, so the coast and its gate are dropped rather than left
        // open for a later message to resume.
        if !routed { driver.abandonHostMomentum() }
        if !running { stopCoast() }
    }
    deinit { coastTimer?.cancel() }
    private func stopCoast() {
        coastTimer?.cancel()
        coastTimer = nil
        coastRoute = nil
    }
    var isCoasting: Bool { withAuthority { driver.isCoasting } }

    init(driver: RemoteInputDriver = RemoteInputDriver(),
         queue: DispatchQueue = DispatchQueue(label: "farside.input.post", qos: .userInteractive),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         coalesceCouchMotion: @escaping () -> Bool = { !UserDefaults.standard.bool(forKey: HostInputExecutor.couchBurstDisabledDefaultsKey) }) {
        self.driver = driver; self.queue = queue; self.clock = clock; self.coalesceCouchMotion = coalesceCouchMotion
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
                    coastIfStarted(routeAuthority)
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
            coastIfStarted { $0() }
            return outcome
        }
    }
    func drain() { queue.sync {} }
}

extension HostInputExecutor {
    /// Submits through `peer`'s posting authority while `peer` is still `owner`'s live route, and hands
    /// the receipt to `deliver` on main only if it still is. False only when the queue refused the input.
    ///
    /// Keep this straight-line. Swift 6.4 (swiftlang-6.4.0.34.1) deallocates the second weak capture of
    /// `let post = { [weak a, weak b] in … }; post()` before the call; the 20260930.8 host then loaded that
    /// dead `PeerMedia` slot (objc poison 0x0fad…) and crashed in `objc_retain`.
    @MainActor
    func post<Owner: AnyObject, R>(
        owner: Owner, peer: PeerMedia, isLive: @escaping @MainActor (Owner, PeerMedia) -> Bool,
        submit: (_ routeAuthority: @escaping (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome,
                 _ completion: @escaping (R) -> Void) -> Bool,
        deliver: @escaping @MainActor (Owner, R) -> Void
    ) -> Bool {
        guard isLive(owner, peer) else { return true }
        return submit({ operation in peer.withInputPostingAuthority(operation) ?? RemoteInputOutcome() },
                      { [weak owner, weak peer] receipt in
                          MainActor.assumeIsolated {
                              guard let owner, let peer, isLive(owner, peer) else { return }
                              deliver(owner, receipt)
                          }
                      })
    }
}
