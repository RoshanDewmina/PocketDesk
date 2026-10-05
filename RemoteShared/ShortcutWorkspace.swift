import Foundation

struct ScopedChordRequest: Codable, Equatable {
    enum Operation: String, Codable { case context, post }
    let operation: Operation
    var bundleID: String? = nil
    var context: String? = nil
    var key: String? = nil
    var modifiers: [String] = []
    func validate() throws {
        switch operation {
        case .context:
            guard let bundleID, !bundleID.isEmpty, bundleID.utf8.count <= 255,
                  bundleID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  context == nil, key == nil, modifiers.isEmpty else { throw RemoteError.invalidMessage }
        case .post:
            guard bundleID == nil, let context, InputCausalEnvelope.validID(context), let key,
                  ScopedChordPolicy.valid(key: key, modifiers: modifiers) else { throw RemoteError.invalidMessage }
        }
    }
}
struct ScopedChordReply: Codable, Equatable {
    enum Outcome: String, Codable { case ready, posted, rejected, uncertain }
    let outcome: Outcome
    var context: String? = nil
    var bundleID: String? = nil
    func validate() throws {
        if outcome == .ready {
            guard let context, InputCausalEnvelope.validID(context), let bundleID, !bundleID.isEmpty, bundleID.utf8.count <= 255 else { throw RemoteError.invalidMessage }
        } else if context != nil || bundleID != nil { throw RemoteError.invalidMessage }
    }
}
enum ScopedChordPolicy {
    static let keys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + ["return", "tab", "space", "escape", "delete", "forwardDelete", "left", "right", "up", "down", "home", "end", "pageUp", "pageDown"]
    static let modifiers = ["command", "shift", "option", "control"]
    static func valid(key: String, modifiers: [String]) -> Bool {
        keys.contains(key) && modifiers.count <= 4 && Set(modifiers).count == modifiers.count && modifiers.allSatisfy(Self.modifiers.contains)
    }
    static func current(issuedAt: TimeInterval, now: TimeInterval, expectedPID: Int32, currentPID: Int32,
                        expectedLaunch: Date, currentLaunch: Date?, generation: UInt64, currentGeneration: UInt64, secure: Bool) -> Bool {
        !secure && generation == currentGeneration && expectedPID == currentPID && expectedLaunch == currentLaunch &&
        now >= issuedAt && now - issuedAt <= 5
    }
}

/// Duplicate reliable deliveries must not race an in-flight posted receipt with a rejected reply.
struct ScopedChordRequestLedger {
    private var seen: Set<String> = []
    private var order: [String] = []
    mutating func insert(_ id: String) -> Bool {
        guard InputCausalEnvelope.validID(id), !seen.contains(id) else { return false }
        seen.insert(id); order.append(id)
        if order.count > 128 { seen.remove(order.removeFirst()) }
        return true
    }
    mutating func retire() { seen = []; order = [] }
}
