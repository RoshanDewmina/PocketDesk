import Foundation

/// Opaque local registration only. Remote peers never supply a hardware/network destination.
struct WakeRequest: Codable, Equatable {
    let targetID: UUID
    let requestID: String
    func validate() throws {
        guard Self.validID(requestID) else { throw RemoteError.invalidMessage }
    }
    static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct WakeReply: Codable, Equatable {
    enum Status: String, Codable { case sent, unsupported, denied }
    let targetID: UUID
    let requestID: String
    let status: Status
    func validate() throws { guard WakeRequest.validID(requestID) else { throw RemoteError.invalidMessage } }
}

