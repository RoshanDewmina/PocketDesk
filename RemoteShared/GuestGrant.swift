import Foundation

/// Guest identity is separate from native owner pairing and never conveys control authority.
struct GuestGrant: Codable, Equatable, Sendable {
    var version = 1
    let hostID: String
    let grantID: String
    let ownerSessionID: String
    let scopeEpoch: String
    let geometryEpoch: String
    let scopeKind: String
    let requestID: String
    let recipientPublicKey: String
    let recipientAgreementKey: String
    let hostAgreementKey: String
    let recipientNonce: String
    let hostNonce: String
    let origin: String
    let issuedAt: Int64
    let expiresAt: Int64
    let ticketHash: String
    var mode = "view"

    func validate(at milliseconds: Int64) throws {
        guard version == 1, mode == "view", [hostID, grantID, ownerSessionID, requestID, recipientNonce, hostNonce, ticketHash].allSatisfy(GuestValidation.token),
              GuestValidation.epoch(scopeEpoch), GuestValidation.epoch(geometryEpoch),
              ["display", "application", "window"].contains(scopeKind),
              [recipientPublicKey, recipientAgreementKey, hostAgreementKey].allSatisfy(GuestValidation.publicKey),
              GuestValidation.origin(origin), issuedAt > 0, issuedAt <= milliseconds,
              expiresAt > milliseconds, expiresAt > issuedAt, expiresAt - issuedAt <= 600_000,
              expiresAt <= 9_007_199_254_740_991 else { throw GuestValidation.Failure.invalidGrant }
    }

    var signedFields: [String] {
        ["grant", origin, hostID, grantID, ownerSessionID, scopeEpoch, geometryEpoch, scopeKind, mode,
         requestID, recipientPublicKey, recipientAgreementKey, hostAgreementKey, recipientNonce,
         hostNonce, String(issuedAt), String(expiresAt), ticketHash]
    }
}

enum GuestValidation {
    enum Failure: Error { case invalidGrant, invalidMessage, closed }
    static func token(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func epoch(_ value: String) -> Bool {
        guard let parsed = UInt64(value), parsed > 0 else { return false }
        return String(parsed) == value
    }
    static func publicKey(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count == 65 && data.first == 4 && data.base64EncodedString() == value
    }
    static func origin(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, let url = parts.url else { return false }
        guard parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { return false }
        return url.absoluteString == value
    }
}

/// Terminal source-to-guest fence. Lock order: capture scope lease → guest lease → guest peer.
/// Replication permission is renewable but can never extend the immutable guest grant deadline.
final class GuestCaptureLease: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    let grantID: String
    let ownerSessionID: String
    let scopeEpoch: String
    let geometryEpoch: String
    private let expiresAt: TimeInterval
    private var permitUntil: TimeInterval = 0
    private var closed = false

    init(grantID: String, ownerSessionID: String, scopeEpoch: String, geometryEpoch: String,
         expiresAt: TimeInterval, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.grantID = grantID; self.ownerSessionID = ownerSessionID
        self.scopeEpoch = scopeEpoch; self.geometryEpoch = geometryEpoch
        self.expiresAt = expiresAt; self.clock = clock
    }
    func permit(until deadline: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, deadline.isFinite else { return }
        permitUntil = min(deadline, expiresAt)
    }
    func pause() { lock.lock(); permitUntil = 0; lock.unlock() }
    @discardableResult
    func deliver(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard !closed, now.isFinite, expiresAt.isFinite, now < expiresAt, now < permitUntil else { return false }
        body(); return true
    }
    func close() { lock.lock(); closed = true; permitUntil = 0; lock.unlock() }
}
