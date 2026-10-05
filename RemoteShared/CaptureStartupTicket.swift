import Foundation

/// A callback may never arrive. Caller deadlines do not prove the OS producer retired.
final class CaptureStartupTicket: @unchecked Sendable {
    enum Failure: Error { case deadline, cleanupPending }
    typealias Completion = @Sendable (Error?) -> Void
    private let lock = NSLock()
    private let startOperation: (@escaping Completion) -> Void
    private let stopOperation: (@escaping Completion) -> Void
    private let fence: () -> Void
    private let retired: () -> Void
    private let stoppedError: (Error) -> Bool
    private let event: (String) -> Void
    private var started = false
    private var settled = false
    private var startSucceeded = false
    private var firstFrame = false
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var retiring = false
    private var fenced = false
    private var pendingStop = 0
    private var confirmed = false
    private var retirementComplete = false
    private var stopPending = false
    private var preStopIssued = false
    private var postStopIssued = false
    private var retirementWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(start: @escaping (@escaping Completion) -> Void,
         stop: @escaping (@escaping Completion) -> Void,
         fence: @escaping () -> Void, retired: @escaping () -> Void,
         stoppedError: @escaping (Error) -> Bool, event: @escaping (String) -> Void = { _ in }) {
        startOperation = start; stopOperation = stop; self.fence = fence
        self.retired = retired; self.stoppedError = stoppedError; self.event = event
    }

    var retirementConfirmed: Bool { lock.withLock { retirementComplete } }

    var isReady: Bool { lock.withLock { startSucceeded && firstFrame && !retiring } }

    func start(timeout: TimeInterval = 5) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let launch = lock.withLock { () -> Bool in
                    if let result { continuation.resume(with: result); return false }
                    precondition(self.continuation == nil && !started)
                    self.continuation = continuation; started = true
                    return true
                }
                if launch {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in deadlineExpired() }
                    startOperation { [self] in startSettled($0) }
                }
            }
        } onCancel: { self.fail(CancellationError()) }
    }

    func completeFrame() {
        let completion = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !retiring else { return nil }
            firstFrame = true
            return finishReadyLocked()
        }
        completion?.resume()
    }

    private func finishReadyLocked() -> CheckedContinuation<Void, Error>? {
        guard startSucceeded && firstFrame && result == nil else { return nil }
        result = .success(())
        let completion = continuation; continuation = nil
        return completion
    }

    private func startSettled(_ error: Error?) {
        let change = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
            guard !settled else { return (false, nil) }
            settled = true; startSucceeded = error == nil
            return (true, retiring || error != nil ? nil : finishReadyLocked())
        }
        guard change.0 else { return }
        event(error == nil ? "start.settled.success" : "start.settled.failure")
        change.1?.resume()
        if let error { fail(error) }
        issueCleanupIfNeeded()
    }

    func deadlineExpired() {
        retire(error: Failure.deadline, onlyPending: true)
    }

    func fail(_ error: Error) { retire(error: error) }
    func requestStop() { retire(error: CancellationError()) }

    private func retire(error: Error, onlyPending: Bool = false) {
        let change = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
            guard !retiring, !onlyPending || result == nil else { return (false, nil) }
            retiring = true
            if result == nil { result = .failure(error) }
            let completion = continuation; continuation = nil
            return (true, completion)
        }
        // Fence before releasing the waiting caller, without holding the ticket lock.
        if change.0 {
            fence(); lock.withLock { fenced = true }
            if (error as? Failure) == .deadline { event("startup.deadline") }
        }
        change.1?.resume(throwing: error)
        issueCleanupIfNeeded()
    }

    private func issueCleanupIfNeeded() {
        let action = lock.withLock { () -> Int in
            guard retiring && fenced && !confirmed && !stopPending else { return 0 }
            if !started { confirmed = true; return 3 }
            if settled {
                guard !postStopIssued else { return 0 }
                postStopIssued = true; stopPending = true; pendingStop = 2; return 2
            }
            guard !preStopIssued else { return 0 }
            preStopIssued = true; stopPending = true; pendingStop = 1; return 1
        }
        if action == 3 { finishRetirement(); return }
        guard action != 0 else { return }
        event(action == 2 ? "stop.request.afterSettlement" : "stop.request.pendingStart")
        stopOperation { [self] error in
            let didRetire = lock.withLock { () -> Bool in
                guard stopPending && pendingStop == action else { return false }
                stopPending = false
                // A stop during a pending start cannot settle that later start, even -3808.
                if action == 2 && (error == nil || stoppedError(error!)) {
                    confirmed = true; return true
                }
                return false
            }
            if didRetire { finishRetirement() }
            else { issueCleanupIfNeeded() }
        }
    }

    private func finishRetirement() {
        event("stop.retirement.confirmed")
        retired()
        let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            retirementComplete = true
            let values = Array(retirementWaiters.values); retirementWaiters.removeAll(); return values
        }
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitForRetirement(timeout: TimeInterval = 3) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let waiting = lock.withLock { () -> Bool in
                if retirementComplete { return false }
                retirementWaiters[id] = continuation; return true
            }
            guard waiting else { continuation.resume(returning: true); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                let waiter = lock.withLock { retirementWaiters.removeValue(forKey: id) }
                waiter?.resume(returning: false)
            }
        }
    }
}

/// Holds at most one producer, including a quarantined producer with missing OS callbacks.
final class CaptureProducerReservation: @unchecked Sendable {
    static let shared = CaptureProducerReservation()
    private let lock = NSLock()
    private var token: UUID?
    private var retained: AnyObject?
    var isReserved: Bool { lock.withLock { token != nil } }

    func reserve() throws -> UUID {
        try lock.withLock {
            guard token == nil else { throw CaptureStartupTicket.Failure.cleanupPending }
            let next = UUID(); token = next; return next
        }
    }
    func retain(_ producer: AnyObject, token: UUID) { lock.withLock { if self.token == token { retained = producer } } }
    func release(_ token: UUID) { lock.withLock { if self.token == token { retained = nil; self.token = nil } } }
}

struct CaptureStartupRecoveryPolicy {
    static func admitsCallback(ready: Bool, scopeValid: Bool, stopping: Bool) -> Bool {
        ready && scopeValid && !stopping
    }

    static func permits(remaining: Bool, retired: Bool, exactAdmission: Bool,
                        activePicture: Bool, paused: Bool, locked: Bool,
                        permissions: Bool, routeTrusted: Bool, viewOnly: Bool) -> Bool {
        remaining && retired && exactAdmission && activePicture && !paused && !locked && permissions && routeTrusted && !viewOnly
    }
}

struct CaptureStartupTimeout: Error { let ticket: CaptureStartupTicket }

struct CaptureStartupFaultPolicy {
    private(set) var consumed = false
    mutating func consume(requested: Bool, debugBuild: Bool) -> Bool {
        guard debugBuild, requested, !consumed else { return false }
        consumed = true
        return true
    }
}
