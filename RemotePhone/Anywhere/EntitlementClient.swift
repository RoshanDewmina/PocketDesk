import Foundation

struct EntitlementVerifyRequest: Equatable {
    var signedTransaction: String
    var deviceID: String
}

/// The service's answer: whether this subscription may use Anywhere and, if so, a short-lived token
/// the signaling service accepts in `register` (Backend/ENTITLEMENT-CONTRACT.md §2–3).
struct EntitlementGrant: Equatable, Codable {
    var entitled: Bool
    var expiresAt: Date?
    var environment: String?
    /// Why there is no access when `entitled` is false: "expired", "revoked" or "device_limit".
    var reason: String?
    var inGracePeriod = false
    var token: String?
    var tokenExpiresAt: Date?
    var issuedAt: Date

    func tokenValid(at now: Date, margin: TimeInterval = 5) -> Bool {
        guard entitled, let token, !token.isEmpty, let tokenExpiresAt else { return false }
        return tokenExpiresAt.timeIntervalSince(now) > margin
    }

    /// Contract §2(c): ask again once the token is older than 12 hours or has less than 6 hours left.
    func needsRefresh(at now: Date) -> Bool {
        guard tokenValid(at: now), let tokenExpiresAt else { return true }
        return now.timeIntervalSince(issuedAt) > 12 * 3600 || tokenExpiresAt.timeIntervalSince(now) < 6 * 3600
    }

    /// When to refresh while the app keeps running: at the 12-hour or 6-hours-left mark, whichever is
    /// first, but never sooner than a minute and always before the token lapses.
    func refreshDate(now: Date) -> Date? {
        guard let tokenExpiresAt, tokenValid(at: now) else { return nil }
        let due = min(issuedAt.addingTimeInterval(12 * 3600), tokenExpiresAt.addingTimeInterval(-6 * 3600))
        if due > now.addingTimeInterval(60) { return due }
        let remaining = tokenExpiresAt.timeIntervalSince(now)
        return now.addingTimeInterval(max(min(60, remaining / 2), remaining * 0.8))
    }
}

enum EntitlementServiceError: Error, Equatable {
    /// The service looked and refused (400 or 401), with its reason when it gave one. Retrying the
    /// same transaction will not help.
    case rejected(status: Int, reason: String?)
    /// 429: back off for this long.
    case rateLimited(retryAfter: TimeInterval?)
    /// No answer, a timeout or a 5xx. Keep using an unexpired token; the same Wi-Fi still works.
    case unreachable
    case invalidResponse
}

protocol EntitlementVerifying {
    func verify(_ request: EntitlementVerifyRequest) async throws -> EntitlementGrant
}

/// The one place the verify endpoint's wire format lives (Backend/ENTITLEMENT-CONTRACT.md v1).
///
///     POST {base}/v1/entitlements/verify   {"signedTransaction": "<JWS>", "deviceId": "<64 hex>"}
///     200 {"entitled": true, "expiresAt": "…", "environment": "Production", "productId": "…",
///          "inGracePeriod": false, "entitlementToken": "fe1…", "tokenExpiresAt": "…"}
///     200 {"entitled": false, "reason": "expired" | "revoked" | "device_limit", …}
///
/// The token is opaque; only `tokenExpiresAt` says how long it lasts.
struct EntitlementWire {
    var path = "/v1/entitlements/verify"
    /// Only if a service ever omits `tokenExpiresAt`: short, so a stale token is not reused for long.
    var fallbackTokenLifetime: TimeInterval = 10 * 60

    func body(for request: EntitlementVerifyRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["signedTransaction": request.signedTransaction,
                                                    "deviceId": request.deviceID], options: [.sortedKeys])
    }

    func grant(from data: Data, now: Date) throws -> EntitlementGrant {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entitled = object["entitled"] as? Bool else { throw EntitlementServiceError.invalidResponse }
        let token = entitled ? (object["entitlementToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
        let tokenExpiry = token.map { _ in
            (object["tokenExpiresAt"] as? String).flatMap(Self.date) ?? now.addingTimeInterval(fallbackTokenLifetime)
        }
        return EntitlementGrant(entitled: entitled, expiresAt: (object["expiresAt"] as? String).flatMap(Self.date),
                                environment: object["environment"] as? String, reason: object["reason"] as? String,
                                inGracePeriod: object["inGracePeriod"] as? Bool ?? false,
                                token: token, tokenExpiresAt: tokenExpiry, issuedAt: now)
    }

    func error(status: Int, data: Data) -> EntitlementServiceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 429:
            return .rateLimited(retryAfter: (object?["retryAfterSeconds"] as? NSNumber)?.doubleValue)
        case 400..<500:
            return .rejected(status: status, reason: (object?["reason"] as? String) ?? (object?["error"] as? String))
        default:
            return .unreachable
        }
    }

    static func date(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

struct HTTPEntitlementClient: EntitlementVerifying {
    let baseURL: URL
    var session: URLSession = .shared
    var wire = EntitlementWire()
    var timeout: TimeInterval = 10
    var now: () -> Date = Date.init

    func verify(_ request: EntitlementVerifyRequest) async throws -> EntitlementGrant {
        var http = URLRequest(url: baseURL.appending(path: wire.path), timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try wire.body(for: request)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: http) }
        catch { throw EntitlementServiceError.unreachable }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw EntitlementServiceError.invalidResponse }
        guard (200..<300).contains(status) else { throw wire.error(status: status, data: data) }
        return try wire.grant(from: data, now: now())
    }
}

/// Random identifiers for this install, kept in this device's Keychain (not backed up to other
/// devices). `deviceID` (64 hex, contract §1) goes only to the entitlement service; `accountToken`
/// is the purchase's `appAccountToken`. Neither is derived from an Apple ID, name or vendor id.
/// A restored subscription carries the token of the install that bought it, so nothing may require
/// the two to match.
enum InstallIdentity {
    struct Identity: Codable, Equatable {
        var deviceID: String
        var accountToken: UUID
    }

    nonisolated(unsafe) private static var cached: Identity?
    private static let lock = NSLock()

    static func current(store: any PairPersistence = PairStore(account: "anywhere.install")) -> Identity? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        do {
            if let stored = try store.read(Identity.self), SecureRandom.isToken(stored.deviceID) {
                cached = stored
                return stored
            }
            let fresh = Identity(deviceID: try SecureRandom.token(), accountToken: UUID())
            try store.save(fresh)
            cached = fresh
            return fresh
        } catch {
            // A locked Keychain: never invent a second identity; try again next time.
            return nil
        }
    }

    static func resetCacheForTesting() {
        lock.lock(); cached = nil; lock.unlock()
    }
}
