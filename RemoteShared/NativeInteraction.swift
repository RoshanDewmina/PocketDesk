import Foundation

/// Optional native capability envelope. Legacy clients ignore it on existing status actions.
/// A host-issued token expires on the host clock; clients echo it without interpreting time.
struct NativeInteraction: Codable, Equatable {
    var version: Int = 1
    var token: String? = nil
    var hold: String? = nil
    var clickCount: Int? = nil
    var phase: String? = nil
    var stream: String? = nil
    var doubleClickInterval: Double? = nil

    func validate() throws {
        guard version == 1,
              [token, hold, stream].allSatisfy({ $0 == nil || (!$0!.isEmpty && $0!.utf8.count <= 64) }),
              clickCount == nil || (1...3).contains(clickCount!),
              phase == nil || ["began", "changed", "ended", "cancelled", "momentum"].contains(phase!),
              doubleClickInterval == nil || (doubleClickInterval!.isFinite && (0.1...2).contains(doubleClickInterval!))
        else { throw RemoteError.invalidMessage }
    }
}
