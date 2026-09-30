import Foundation
import CryptoKit
import Security

struct PairInvitation: Codable, Equatable {
    var version = 1
    var server: String
    var room: String
    var token: String
    var key: Data
    var expires: Date
    var name: String
    /// Stable host and owner-pair identities are independent of renewable signaling rooms.
    var durableHostID: String? = nil
    var ownerPairID: String? = nil
    /// Opaque local discovery locator; it is never authentication or route proof.
    var localServiceName: String? = nil

    func validate(now: Date = Date(), enrollment: Bool = true) throws {
        guard version == 1, SecureRandom.isToken(room), SecureRandom.isToken(token), key.count == 32,
              !name.isEmpty, name.utf8.count <= 128,
              !enrollment || (expires > now && expires.timeIntervalSince(now) <= 180),
              Self.validServer(server) else { throw RemoteError.invalidPairing }
        guard durableHostID == nil || durableHostID.map(SecureRandom.isToken) == true,
              ownerPairID == nil || ownerPairID.map(SecureRandom.isToken) == true else {
            throw RemoteError.invalidPairing
        }
        if let localServiceName {
            guard !localServiceName.isEmpty, localServiceName.utf8.count <= 63,
                  !localServiceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw RemoteError.invalidPairing }
        }
    }
    static func validServer(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == "/signal" else { return false }
        if url.scheme == "wss" { return !host.isEmpty }
        return url.scheme == "ws" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }
    func code() throws -> String {
        "pocketdesk:" + (try JSONEncoder().encode(self)).base64EncodedString()
    }
    static func parse(_ text: String, now: Date = Date()) throws -> Self {
        guard text.utf8.count < 4096, text.hasPrefix("pocketdesk:"),
              let data = Data(base64Encoded: String(text.dropFirst(11))) else { throw RemoteError.invalidPairing }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(now: now)
        return result
    }
}

/// The HTTPS origin and proof for one exact pairing. A later pairing never reuses this target.
struct PushPairingTarget: Codable, Hashable {
    let room: String
    let token: String
    let origin: URL

    /// Opaque APNs identity for this exact room and phone proof. Neither proof nor origin travels
    /// in the notification payload; the service derives the same value from its pairing hash.
    var notificationIdentity: String { Self.notificationIdentity(room: room, token: token) }

    static func notificationIdentity(room: String, token: String) -> String {
        SecureRandom.digest(room + ":" + SecureRandom.digest(token))
    }

    init?(invitation: PairInvitation) {
        guard SecureRandom.isToken(invitation.room), SecureRandom.isToken(invitation.token),
              let origin = Self.origin(for: invitation.server) else { return nil }
        room = invitation.room
        token = invitation.token
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case room, token, origin }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let room = try values.decode(String.self, forKey: .room)
        let token = try values.decode(String.self, forKey: .token)
        let origin = try values.decode(URL.self, forKey: .origin)
        guard SecureRandom.isToken(room), SecureRandom.isToken(token),
              let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw DecodingError.dataCorruptedError(forKey: .origin, in: values, debugDescription: "Invalid push target")
        }
        self.room = room
        self.token = token
        self.origin = origin
    }

    static func origin(for server: String) -> URL? {
        guard PairInvitation.validServer(server),
              var parts = URLComponents(string: server), parts.scheme == "wss",
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.path == "/signal", parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = "https"
        parts.path = ""
        return parts.url
    }
}

extension PairInvitation {
    var notificationIdentity: String { PushPairingTarget.notificationIdentity(room: room, token: token) }
}

struct HostPair: Codable {
    var hostToken: String
    var invitation: PairInvitation
    var paired: Bool
    /// The paired phone's display name, sent inside the sealed `acceptedAck` (D39). Nil for pairs
    /// made before phones sent one; a new pairing starts without it.
    var phoneName: String? = nil

    static func create(server: String, name: String, identity: HostIdentityRecord? = nil) throws -> Self {
        let token = try SecureRandom.token()
        return HostPair(hostToken: token, invitation: PairInvitation(server: server,
            room: SecureRandom.digest(token), token: try SecureRandom.token(), key: try SecureRandom.bytes(),
            expires: Date().addingTimeInterval(120), name: String(name.prefix(100)),
            durableHostID: identity?.hostID, ownerPairID: identity == nil ? nil : try SecureRandom.token(),
            localServiceName: identity?.localServiceName), paired: false)
    }
    func rotated() throws -> Self {
        var next = self
        next.invitation.token = try SecureRandom.token()
        next.invitation.key = try SecureRandom.bytes()
        next.invitation.expires = .distantFuture
        next.paired = true
        return next
    }
}

enum SecureRandom {
    static func bytes() throws -> Data {
        var value = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, value.count, &value) == errSecSuccess else { throw RemoteError.random }
        return Data(value)
    }
    static func token() throws -> String { try bytes().map { String(format: "%02x", $0) }.joined() }
    static func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func isToken(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum RemoteError: Error, LocalizedError {
    case invalidPairing, random, invalidMessage, stale, keychain(OSStatus), backpressure
    var errorDescription: String? {
        switch self {
        case .invalidPairing: "The pairing code is invalid or expired. Open Pair Phone on your Mac."
        case .random: "Secure pairing could not be created. Try again."
        case .invalidMessage: "The connection could not be authenticated. Pair again on your Mac."
        case .stale: "An old session message was rejected. Reconnect to continue."
        case .keychain: "Device trust could not be saved in Keychain. Unlock this device and try again."
        case .backpressure: "The connection is too busy. Control has been paused."
        }
    }
}

struct ProtectedMessage: Codable {
    var version = 1
    var kind: String
    var request: String
    var session: String
    var sequence: UInt64
    var body: Data?
}

struct SignalCipher {
    let key: SymmetricKey
    let room: String
    init(key: Data, room: String) throws {
        guard key.count == 32, SecureRandom.isToken(room) else { throw RemoteError.invalidPairing }
        self.key = SymmetricKey(data: key); self.room = room
    }
    func seal(_ message: ProtectedMessage, sender: String) throws -> String {
        let bytes = try JSONEncoder().encode(message)
        guard bytes.count <= 128 * 1024, ["host", "client"].contains(sender) else { throw RemoteError.invalidMessage }
        let box = try AES.GCM.seal(bytes, using: key, authenticating: Data("PocketDesk-v1|\(room)|\(sender)".utf8))
        guard let combined = box.combined else { throw RemoteError.invalidMessage }
        return combined.base64EncodedString()
    }
    func open(_ value: String, sender: String) throws -> ProtectedMessage {
        guard value.utf8.count <= 180 * 1024, let data = Data(base64Encoded: value),
              ["host", "client"].contains(sender) else { throw RemoteError.invalidMessage }
        let box = try AES.GCM.SealedBox(combined: data)
        let bytes = try AES.GCM.open(box, using: key, authenticating: Data("PocketDesk-v1|\(room)|\(sender)".utf8))
        guard bytes.count <= 128 * 1024 else { throw RemoteError.invalidMessage }
        let result = try JSONDecoder().decode(ProtectedMessage.self, from: bytes)
        guard result.version == 1, SecureRandom.isToken(result.request),
              result.session.isEmpty || SecureRandom.isToken(result.session) else { throw RemoteError.invalidMessage }
        return result
    }
}

struct SessionReplayGuard {
    let request: String
    let session: String
    private(set) var lastSequence: UInt64 = 0
    mutating func accept(_ message: ProtectedMessage) throws {
        guard message.request == request, message.session == session, message.sequence > lastSequence else { throw RemoteError.stale }
        lastSequence = message.sequence
    }
}

protocol PairPersistence {
    func save<T: Encodable>(_ value: T) throws
    func read<T: Decodable>(_ type: T.Type) throws -> T?
    func delete() throws
}

#if os(macOS)
// Kept injectable so removal can be checked without touching a real Keychain.
struct PairStoreSecurityCalls {
    let copyMatching: ([String: Any]) -> (OSStatus, Any?)
    let delete: ([String: Any]) -> OSStatus

    static let live = Self(
        copyMatching: { search in
            var output: CFTypeRef?
            let status = SecItemCopyMatching(search as CFDictionary, &output)
            return (status, output)
        },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

enum PairStoreDeletionError: Error, Equatable {
    case invalidPersistentReference
    case recordRemains
}
#endif

struct PairStore: PairPersistence {
    let account: String
#if os(macOS)
    let security: PairStoreSecurityCalls

    init(account: String, security: PairStoreSecurityCalls = .live) {
        self.account = account
        self.security = security
    }
#endif
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PocketDesk.Remote.Trust.v1", kSecAttrAccount as String: account]
    }
    func save<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; updates.forEach { add[$0.key] = $0.value }
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw RemoteError.keychain(result) }
        } else if status != errSecSuccess { throw RemoteError.keychain(status) }
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else { throw RemoteError.keychain(status) }
        return try JSONDecoder().decode(type, from: data)
    }
    func delete() throws {
#if os(macOS)
        var lookup = query
        lookup[kSecReturnPersistentRef as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let (lookupStatus, output) = security.copyMatching(lookup)
        if lookupStatus == errSecItemNotFound {
            try requireAbsent()
            return
        }
        guard lookupStatus == errSecSuccess else { throw RemoteError.keychain(lookupStatus) }
        guard let reference = output as? Data, !reference.isEmpty, reference.count <= 4_096 else {
            throw PairStoreDeletionError.invalidPersistentReference
        }

        // The returned opaque reference identifies just the selected item.
        // Do not carry return options or attributes into a delete query.
        let exactDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchItemList as String: [reference]
        ]
        let deleteStatus = security.delete(exactDelete)
        if deleteStatus == errSecItemNotFound {
            try requireAbsent()
            return
        }
        guard deleteStatus == errSecSuccess else { throw RemoteError.keychain(deleteStatus) }
        try requireAbsent()
#else
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteError.keychain(status) }
#endif
    }

#if os(macOS)
    private func requireAbsent() throws {
        // Recheck the original class/service/account query. A stale reference or
        // duplicate record must not turn a partial removal into success.
        let (status, _) = security.copyMatching(query)
        if status == errSecItemNotFound { return }
        if status == errSecSuccess { throw PairStoreDeletionError.recordRemains }
        throw RemoteError.keychain(status)
    }
#endif
}
