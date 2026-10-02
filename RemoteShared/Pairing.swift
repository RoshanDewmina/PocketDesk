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
    /// Identity presence is a prerequisite only; it never proves a route or owner authority.
    var hasOwnerLocalIdentity: Bool { durableHostID != nil && ownerPairID != nil && localServiceName != nil }

    func validate(now: Date = Date(), enrollment: Bool = true) throws {
        guard (version == 1 || version == PairEnrollment.version), SecureRandom.isToken(room), SecureRandom.isToken(token), key.count == 32,
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

/// Each approved device retains its own secret and pair identity within the Mac's stable room.
struct HostPairedDevice: Codable, Equatable, Identifiable {
    var invitation: PairInvitation
    var phoneName: String?
    var lastUsed: Date?
    var id: String { invitation.ownerPairID ?? SecureRandom.digest(invitation.token) }
}

enum HostDeviceLimitError: Error, LocalizedError {
    case full, busy, serviceChanged, disabled
    var errorDescription: String? {
        switch self {
        case .full: "This Mac already remembers five devices. Remove one in Settings before pairing another."
        case .busy: "Disconnect the current device and finish any Mac approval before pairing another."
        case .disabled: "Adding devices is temporarily unavailable on this Mac."
        case .serviceChanged: "Remove the saved devices before changing this Mac’s connection service."
        }
    }
}

struct HostPair: Codable {
    var hostToken: String
    var invitation: PairInvitation
    var paired: Bool
    /// The paired phone's display name, sent inside the sealed `acceptedAck` (D39). Nil for pairs
    /// made before phones sent one; a new pairing starts without it.
    var phoneName: String? = nil
    /// Nil is the legacy single-device record. Empty is deliberately no approved devices.
    var devices: [HostPairedDevice]? = nil
    var lastUsed: Date? = nil
    var pendingInvitation: PairInvitation? = nil

    var approvedDevices: [HostPairedDevice] {
        devices ?? (paired ? [HostPairedDevice(invitation: invitation, phoneName: phoneName, lastUsed: lastUsed)] : [])
    }

    func validatedCatalog() throws -> Self {
        try invitation.validate(enrollment: false)
        guard SecureRandom.isToken(hostToken), SecureRandom.digest(hostToken) == invitation.room,
              approvedDevices.count <= 5 else { throw RemoteError.invalidPairing }
        var tokens = Set<String>(), keys = Set<Data>(), identities = Set<String>()
        for device in approvedDevices {
            try device.invitation.validate(enrollment: false)
            guard device.invitation.room == invitation.room, device.invitation.server == invitation.server,
                  device.invitation.durableHostID == invitation.durableHostID,
                  tokens.insert(device.invitation.token).inserted, keys.insert(device.invitation.key).inserted,
                  identities.insert(device.id).inserted else { throw RemoteError.invalidPairing }
        }
        if let pendingInvitation {
            try pendingInvitation.validate(enrollment: false)
            guard pendingInvitation.room == invitation.room, pendingInvitation.server == invitation.server,
                  pendingInvitation.durableHostID == invitation.durableHostID,
                  !tokens.contains(pendingInvitation.token), !keys.contains(pendingInvitation.key),
                  !identities.contains(pendingInvitation.ownerPairID ?? SecureRandom.digest(pendingInvitation.token)),
                  approvedDevices.count < 5 else { throw RemoteError.invalidPairing }
        }
        if paired, !approvedDevices.contains(where: { $0.invitation == invitation }) { throw RemoteError.invalidPairing }
        var migrated = self
        migrated.devices = approvedDevices
        return migrated
    }

    func selecting(_ device: HostPairedDevice) -> Self {
        var next = self
        next.invitation = device.invitation; next.phoneName = device.phoneName
        next.lastUsed = device.lastUsed; next.paired = true
        return next
    }

    mutating func rememberCurrentDevice(at now: Date = Date()) throws {
        var all = approvedDevices
        let device = HostPairedDevice(invitation: invitation, phoneName: phoneName, lastUsed: now)
        if let index = all.firstIndex(where: { $0.id == device.id }) { all[index] = device }
        else {
            guard all.count < 5 else { throw HostDeviceLimitError.full }
            all.append(device)
        }
        devices = all; lastUsed = now
    }

    static func create(server: String, name: String, identity: HostIdentityRecord? = nil) throws -> Self {
        let token = try SecureRandom.token()
        return HostPair(hostToken: token, invitation: PairInvitation(version: PairEnrollment.version, server: server,
            room: SecureRandom.digest(token), token: try SecureRandom.token(), key: try SecureRandom.bytes(),
            expires: Date().addingTimeInterval(120), name: String(name.prefix(100)),
            durableHostID: identity?.hostID, ownerPairID: identity == nil ? nil : try SecureRandom.token(),
            localServiceName: identity?.localServiceName), paired: false)
    }
    func rotated() throws -> Self {
        var next = self
        next.invitation.version = 1
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
    case invalidPairing, pairingUpgradeRequired, localPairingRefreshRequired, random, invalidMessage, stale, keychain(OSStatus), backpressure
    var errorDescription: String? {
        switch self {
        case .invalidPairing: "The pairing code is invalid or expired. Open Pair Phone on your Mac."
        case .pairingUpgradeRequired: "Update Farside on both your Mac and phone, then create a fresh pairing code."
        case .localPairingRefreshRequired: "Local network only requires a fresh owner-approved QR code from your Mac. Connect normally or re-pair to enable it."
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

/// New enrollment alone uses commit/reveal key agreement. QR possession starts an attempt;
/// it never supplies its saved trust key. The phone commits BEFORE the Mac reveals its key,
/// preventing an active QR holder from adapting an ephemeral key to grind a matching short code.
/// Roles, exact QR, request/session, name, features and both fresh key/nonces bind the transcript.
enum PairEnrollment {
    static let version = 2
    static let disabledKey = "farsideDisableComparisonEnrollment"
    struct Reveal: Codable, Equatable {
        let publicKey: Data
        let nonce: Data
    }
    struct Ephemeral {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let reveal: Reveal
        init() throws {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            reveal = Reveal(publicKey: privateKey.publicKey.rawRepresentation, nonce: try SecureRandom.bytes())
        }
    }
    struct Request: Codable {
        var version = PairEnrollment.version
        let commitment: Data
        let handshake: MacShareBlocker.Handshake
        let phoneName: String?
    }
    struct Challenge: Codable {
        var version = PairEnrollment.version
        let reveal: Reveal
    }
    struct Proof: Codable {
        let reveal: Reveal
        let confirmation: Data
        #if DEBUG
        /// Existing private E2E enrollment authorization; absent from Release wire encoding.
        var e2eApproval: Data? = nil
        #endif
    }
    struct Keys {
        let sessionKey: Data
        let trustKey: Data
        let trustToken: String
        let comparisonCode: String
        private let confirmationKey: SymmetricKey
        private let transcriptHash: Data
        func confirmation(role: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: PairEnrollment.canonical([
                Data("Farside-enrollment-v2-confirm".utf8), Data(role.utf8), transcriptHash]), using: confirmationKey))
        }
        func confirms(_ value: Data, role: String) -> Bool {
            HMAC<SHA256>.isValidAuthenticationCode(value, authenticating: PairEnrollment.canonical([
                Data("Farside-enrollment-v2-confirm".utf8), Data(role.utf8), transcriptHash]), using: confirmationKey)
        }
        fileprivate init(secret: SharedSecret, transcript: Data) throws {
            let hash = Data(SHA256.hash(data: transcript))
            func derive(_ label: String) -> Data {
                secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: hash,
                    sharedInfo: Data("Farside-enrollment-v2|\(label)".utf8), outputByteCount: 32)
                    .withUnsafeBytes { Data($0) }
            }
            transcriptHash = hash
            sessionKey = derive("session-cipher")
            trustKey = derive("saved-trust-key")
            trustToken = derive("saved-service-token").map { String(format: "%02x", $0) }.joined()
            confirmationKey = SymmetricKey(data: derive("key-confirmation"))
            // Rejection sampling avoids modulo bias; this is six decimal digits (one in a million
            // per fixed online attempt), not a proof unless the owner compares both screens.
            let bytes = [UInt8](derive("comparison-code"))
            var number: UInt32?
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if value < 4_294_000_000 { number = value % 1_000_000; break }
            }
            guard let number else { throw RemoteError.invalidMessage }
            comparisonCode = String(format: "%03u %03u", number / 1000, number % 1000)
        }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, body: Data?) throws -> T {
        guard let body, body.count <= 4096 else { throw RemoteError.invalidMessage }
        return try JSONDecoder().decode(type, from: body)
    }
    private static func canonical(_ parts: [Data]) -> Data {
        var result = Data()
        for part in parts {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(part)
        }
        return result
    }
    static func commitment(invitation: PairInvitation, requestID: String, reveal: Reveal,
                           handshake: MacShareBlocker.Handshake, phoneName: String?) throws -> Data {
        Data(SHA256.hash(data: canonical([Data("Farside-enrollment-v2-phone-commit".utf8),
            try encoded(invitation), Data(requestID.utf8), try encoded(reveal), try encoded(handshake),
            try encoded(phoneName)])))
    }
    static func validate(_ request: Request) throws {
        guard request.version == version, request.commitment.count == 32,
              request.handshake.features.count <= 8,
              (request.handshake.options?.count ?? 0) <= MacShareBlocker.Handshake.maximumOptions,
              request.handshake.features.allSatisfy({ (1...32).contains($0.utf8.count) }),
              request.phoneName == nil || request.phoneName.map({ PhoneIdentity.sanitized($0) == $0 }) == true else { throw RemoteError.invalidMessage }
    }
    static func derive(invitation: PairInvitation, requestID: String, sessionID: String,
                       request: Request, challenge: Challenge, phone: Reveal,
                       ephemeral: Ephemeral, isHost: Bool) throws -> Keys {
        try invitation.validate()
        try validate(request)
        guard invitation.version == version, challenge.version == version,
              SecureRandom.isToken(requestID), SecureRandom.isToken(sessionID),
              phone.publicKey.count == 32, phone.nonce.count == 32,
              challenge.reveal.publicKey.count == 32, challenge.reveal.nonce.count == 32,
              ephemeral.reveal == (isHost ? challenge.reveal : phone),
              request.commitment == (try commitment(invitation: invitation, requestID: requestID,
                  reveal: phone, handshake: request.handshake, phoneName: request.phoneName)) else { throw RemoteError.invalidMessage }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: isHost ? phone.publicKey : challenge.reveal.publicKey)
        let secret = try ephemeral.privateKey.sharedSecretFromKeyAgreement(with: peer)
        guard secret.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) }) else { throw RemoteError.invalidMessage }
        let transcript = canonical([Data("Farside-enrollment-v2|phone|host".utf8), try encoded(invitation),
            Data(requestID.utf8), Data(sessionID.utf8), try encoded(request), try encoded(challenge), try encoded(phone)])
        return try Keys(secret: secret, transcript: transcript)
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
    var update: ([String: Any], [String: Any]) -> OSStatus = {
        SecItemUpdate($0 as CFDictionary, $1 as CFDictionary)
    }

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
#if os(macOS)
        let status = security.update(query, updates)
#else
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
#endif
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
#if os(macOS)
        let (status, output) = security.copyMatching(search)
#else
        var output: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &output)
#endif
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else { throw RemoteError.keychain(status) }
        if try isRemovedMarker(data) { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    private struct RemovedRecord: Codable {
        var pairStoreRemoval = "revoked.v1"
        var version = 1
        let account: String
    }
    private func isRemovedMarker(_ data: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["pairStoreRemoval"] != nil else { return false }
        guard Set(object.keys) == ["pairStoreRemoval", "version", "account"],
              let marker = try? JSONDecoder().decode(RemovedRecord.self, from: data),
              marker.pairStoreRemoval == "revoked.v1", marker.version == 1,
              marker.account == account else { throw RemoteError.invalidPairing }
        return true
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
        if lookupStatus == errSecInvalidOwnerEdit { try overwriteRemovedMarker(); return }
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
        if deleteStatus == errSecInvalidOwnerEdit { try overwriteRemovedMarker(); return }
        guard deleteStatus == errSecSuccess else { throw RemoteError.keychain(deleteStatus) }
        try requireAbsent()
#else
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteError.keychain(status) }
#endif
    }

#if os(macOS)
    private func overwriteRemovedMarker() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let marker = try encoder.encode(RemovedRecord(account: account))
        // Change data only: never edit Keychain ownership, accessibility, or another account.
        let status = security.update(query, [kSecValueData as String: marker])
        guard status == errSecSuccess else { throw RemoteError.keychain(status) }
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        let (verified, output) = security.copyMatching(search)
        if verified == errSecItemNotFound { return } // Concurrent actual deletion is also absence.
        guard verified == errSecSuccess else { throw RemoteError.keychain(verified) }
        guard let values = output as? [Data], !values.isEmpty,
              values.allSatisfy({ $0 == marker }) else { throw PairStoreDeletionError.recordRemains }
    }
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
