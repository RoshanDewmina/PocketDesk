import Foundation
import CryptoKit

/// This is pair-secret possession evidence, not route evidence or a purchase entitlement.
/// A first pairing still requires the existing Mac-side owner approval; saved pairs may reconnect.
struct LocalOwnerChallenge: Codable, Equatable {
    let hostID: String
    let ownerPairID: String
    let epoch: String
    let nonce: String
    let expires: Date

    static func make(invitation: PairInvitation, now: Date = Date()) throws -> Self {
        guard let hostID = invitation.durableHostID, let pairID = invitation.ownerPairID,
              SecureRandom.isToken(hostID), SecureRandom.isToken(pairID) else { throw RemoteError.invalidPairing }
        return Self(hostID: hostID, ownerPairID: pairID, epoch: String(try SecureRandom.token().prefix(32)),
                    nonce: try SecureRandom.token(), expires: now.addingTimeInterval(20))
    }
    func validate(invitation: PairInvitation, now: Date = Date()) throws {
        guard hostID == invitation.durableHostID, ownerPairID == invitation.ownerPairID,
              SecureRandom.isToken(hostID), SecureRandom.isToken(ownerPairID),
              epoch.count == 32, SecureRandom.isToken(epoch + epoch), SecureRandom.isToken(nonce),
              expires > now, expires.timeIntervalSince(now) <= 20 else { throw RemoteError.stale }
    }
}

struct LocalOwnerResponse: Codable, Equatable {
    let challenge: LocalOwnerChallenge
    let clientNonce: String
    let authentication: Data

    static func make(challenge: LocalOwnerChallenge, invitation: PairInvitation, now: Date = Date()) throws -> Self {
        try challenge.validate(invitation: invitation, now: now)
        let nonce = try SecureRandom.token()
        return Self(challenge: challenge, clientNonce: nonce,
                    authentication: try mac(challenge: challenge, clientNonce: nonce, key: invitation.key))
    }
    private static func authenticatedBody(challenge: LocalOwnerChallenge, clientNonce: String) throws -> Data {
        // Explicit canonical fields; date is integral milliseconds and length-delimited IDs are fixed.
        Data("Farside-local-owner-v1|\(challenge.hostID)|\(challenge.ownerPairID)|\(challenge.epoch)|\(challenge.nonce)|\(Int64(challenge.expires.timeIntervalSince1970 * 1000))|\(clientNonce)".utf8)
    }
    private static func mac(challenge: LocalOwnerChallenge, clientNonce: String, key: Data) throws -> Data {
        guard key.count == 32 else { throw RemoteError.invalidPairing }
        return Data(HMAC<SHA256>.authenticationCode(for: try authenticatedBody(challenge: challenge, clientNonce: clientNonce),
                                                    using: SymmetricKey(data: key)))
    }
    func validate(expected: LocalOwnerChallenge, invitation: PairInvitation, now: Date = Date()) throws {
        try challenge.validate(invitation: invitation, now: now)
        guard challenge == expected, SecureRandom.isToken(clientNonce), invitation.key.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(authentication,
                authenticating: try Self.authenticatedBody(challenge: challenge, clientNonce: clientNonce),
                using: SymmetricKey(data: invitation.key)) else { throw RemoteError.invalidMessage }
    }
}

/// One connection consumes one challenge. Cancellation/revocation drops the whole value;
/// callbacks from another connection cannot reuse this authority.
struct LocalOwnerAdmission {
    let challenge: LocalOwnerChallenge
    private(set) var consumed = false
    mutating func accept(_ response: LocalOwnerResponse, invitation: PairInvitation, now: Date = Date()) throws {
        guard !consumed else { throw RemoteError.stale }
        try response.validate(expected: challenge, invitation: invitation, now: now)
        consumed = true
    }
}

/// Explicit bounded TCP frame codec. Endpoint advertisements and malformed headers never allocate
/// peer-selected unbounded buffers. The transport authenticates content before any relay callback.
enum LocalSignalFraming {
    static let maximumPayload = 256 * 1024
    static func header(length: Int) throws -> Data {
        guard length > 0, length <= maximumPayload else { throw RemoteError.invalidMessage }
        let size = UInt32(length)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
    }
    static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw RemoteError.invalidMessage }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumPayload else { throw RemoteError.invalidMessage }
        return Int(size)
    }
}
