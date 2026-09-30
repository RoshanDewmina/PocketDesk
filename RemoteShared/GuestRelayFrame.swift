import Foundation

/// Optional dedicated signaling management field. Never a RemoteAction or native owner enrollment.
struct GuestRelayFrame: Codable {
    var operation: String
    var grantID: String?
    var inviteHash: String?
    var publicKey: String?
    var hostID: String?
    var ownerSessionID: String?
    var scopeEpoch: String?
    var geometryEpoch: String?
    var scopeKind: String?
    var origin: String?
    var mode: String?
    var issuedAt: Int64?
    var expiresAt: Int64?
    var requestID: String?
    var agreementKey: String?
    var nonce: String?
    var signature: String?
    var grant: GuestGrant?
    var ticket: String?
    var sessionID: String?
    var servers: [ICEServerConfiguration]?
    var envelope: GuestSignalEnvelope?
    var code: String?
    func hasOnlyFields(_ allowed: Set<String>) -> Bool {
        guard let bytes = try? JSONEncoder().encode(self),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return Set(fields.keys) == allowed
    }
}

struct GuestInviteLink: Codable {
    let version: Int
    let room: String
    let grantID: String
    let secret: String
    let publicKey: String
    let expiresAt: Int64
    func url(origin: String) throws -> URL {
        guard version == 1, GuestValidation.origin(origin), [room, grantID, secret].allSatisfy(GuestValidation.token),
              GuestValidation.publicKey(publicKey), var parts = URLComponents(string: origin) else { throw GuestValidation.Failure.invalidMessage }
        parts.path = "/guest"
        parts.fragment = try JSONEncoder().encode(self).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let url = parts.url else { throw GuestValidation.Failure.invalidMessage }; return url
    }
}

/// Current signaling generation owns this value. Reset packets only retire authority.
struct GuestServiceResetGate {
    private var seen: [String] = []
    mutating func accept(_ frame: GuestRelayFrame, currentEpoch: String?) -> Bool {
        guard frame.operation == "serviceReset", frame.hasOnlyFields(["operation", "code", "nonce"]),
              let epoch = currentEpoch, frame.code == epoch,
              let nonce = frame.nonce, GuestValidation.token(nonce), !seen.contains(nonce) else { return false }
        seen.append(nonce)
        if seen.count > 32 { seen.removeFirst() }
        return true
    }
}
