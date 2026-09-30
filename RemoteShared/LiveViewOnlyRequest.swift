import Foundation

/// Applied replies are bound to one request and geometry. Routine health packets
/// cannot complete an enter/exit request that was sent after they were queued.
struct LiveViewOnlyRequest {
    private struct Pending { let id: String; let epoch: UInt64; let deadline: TimeInterval }
    private var pending: Pending?
    var deadline: TimeInterval? { pending?.deadline }
    mutating func begin(epoch: UInt64, at now: TimeInterval) -> String {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        pending = Pending(id: id, epoch: epoch, deadline: now + 2)
        return id
    }
    mutating func receive(_ value: Bool, id: String?, epoch: UInt64, at now: TimeInterval) -> Bool? {
        if let expected = pending {
            guard now.isFinite, now < expected.deadline, id == expected.id, epoch == expected.epoch else { return nil }
            pending = nil; return value
        }
        // An old/duplicate request acknowledgment is not current state evidence.
        return id == nil ? value : nil
    }
    mutating func reset() { pending = nil }
}
