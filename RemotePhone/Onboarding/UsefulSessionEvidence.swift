import Foundation

/// Correlation only; this value never supplies session authority.
struct UsefulSessionContext: Equatable {
    let hostRecordID: String
    let sessionID: UUID
    let contentEpoch: UInt64
    let geometryEpoch: UInt64
}

/// Receipt admission is separate from outbound enqueue and from the person's task outcome.
struct AppliedInputReceiptTracker {
    struct Pending {
        let context: UsefulSessionContext
        let kind: String
        let sentAt: TimeInterval
    }
    static let capacity = 32
    static let lifetime: TimeInterval = 4
    private(set) var pending: [String: Pending] = [:]

    mutating func reserve(kind: String, context: UsefulSessionContext, at now: TimeInterval,
                          requestID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) -> String? {
        pending = pending.filter { now >= $0.value.sentAt && now - $0.value.sentAt <= Self.lifetime }
        guard InputAppliedReceipt.actions.contains(kind), InputCausalEnvelope.validID(requestID),
              context.geometryEpoch > 0, now.isFinite, pending.count < Self.capacity, pending[requestID] == nil else { return nil }
        pending[requestID] = Pending(context: context, kind: kind, sentAt: now)
        return requestID
    }
    mutating func cancel(_ id: String?) { if let id { pending[id] = nil } }
    mutating func clear() { pending.removeAll() }
    mutating func consume(_ receipt: InputAppliedReceipt, epoch: UInt64, context: UsefulSessionContext,
                          at now: TimeInterval) -> Bool {
        guard (try? receipt.validate()) != nil, let item = pending[receipt.requestID] else { return false }
        guard item.kind == receipt.kind else { return false }
        pending[receipt.requestID] = nil // rejected/expired replies are terminal too
        return receipt.accepted && item.context == context && epoch == context.geometryEpoch
            && now.isFinite && now >= item.sentAt && now - item.sentAt <= Self.lifetime
    }
}

struct UsefulSessionEvidence {
    enum Readiness: String { case picture, couch }
    enum Outcome: String, CaseIterable { case read, navigate, edit, save }
    private(set) var context: UsefulSessionContext?
    private(set) var readiness: Readiness?
    private(set) var deadline: TimeInterval = 0
    private(set) var admittedPicture = false
    private(set) var admittedCouch = false
    private(set) var appliedInput = false
    private(set) var outcome: Outcome?

    mutating func admit(_ kind: Readiness, context next: UsefulSessionContext, deadline: TimeInterval, now: TimeInterval) {
        guard deadline.isFinite, now.isFinite, deadline > now, next.geometryEpoch > 0 else { invalidate(); return }
        if context != next { self = Self(); context = next }
        readiness = kind; self.deadline = deadline
        if kind == .picture { admittedPicture = true } else { admittedCouch = true }
    }
    mutating func invalidate() { readiness = nil; deadline = 0 }
    mutating func reset() { self = Self() }
    func ready(at now: TimeInterval) -> Bool { now.isFinite && readiness != nil && now < deadline }
    mutating func applied(context: UsefulSessionContext, now: TimeInterval) -> Bool {
        guard self.context == context, ready(at: now) else { return false }
        appliedInput = true; return true
    }
    @discardableResult mutating func confirm(_ value: Outcome, now: TimeInterval) -> Bool {
        guard ready(at: now), outcome == nil, value == .read || appliedInput else { return false }
        outcome = value; return true
    }
}

/// Product evidence only. Decoding/enqueueing alone cannot mark visible content. Unknown stock
/// or simulator presentation needs the person's explicit visible-picture confirmation.
struct UsefulPictureEvidence {
    private(set) var context: UsefulSessionContext?
    private(set) var receiptID: UUID?
    private(set) var userConfirmed = false
    private var deadline: TimeInterval = 0
    mutating func presented(_ receipt: UUID, context: UsefulSessionContext, deadline: TimeInterval, now: TimeInterval) {
        guard now.isFinite, deadline.isFinite, now < deadline, context.geometryEpoch > 0 else { return }
        if self.context != context { self = Self() }
        guard receiptID != receipt else { return } // A repeated source receipt cannot renew freshness.
        self.context = context; receiptID = receipt; self.deadline = deadline
    }
    mutating func confirmVisible(context: UsefulSessionContext, deadline: TimeInterval, now: TimeInterval) {
        guard now.isFinite, deadline.isFinite, now < deadline, context.geometryEpoch > 0 else { return }
        if self.context != context { self = Self() }
        self.context = context; userConfirmed = true; self.deadline = deadline
    }
    func visibleUntil(context: UsefulSessionContext, now: TimeInterval) -> TimeInterval? {
        guard self.context == context, now.isFinite, now < deadline,
              receiptID != nil || userConfirmed else { return nil }
        return deadline
    }
    func visible(context: UsefulSessionContext, now: TimeInterval) -> Bool {
        visibleUntil(context: context, now: now) != nil
    }
    mutating func invalidate() { self = Self() }
}
