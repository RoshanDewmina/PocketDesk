import CryptoKit
import Foundation
import Security

struct BrowserHostIdentity: Codable, Equatable {
    var version = 1
    var token: String
    var signingPrivateKey: String

    static func create() throws -> Self {
        Self(
            token: try BrowserCrypto.random(),
            signingPrivateKey: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        )
    }

    func signingKey() throws -> P256.Signing.PrivateKey {
        guard version == 1,
              BrowserPeerValidation.isToken(token),
              let data = Data(base64Encoded: signingPrivateKey) else {
            throw BrowserPeerStoreError.invalidRecord
        }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw BrowserPeerStoreError.invalidRecord
        }
    }

    func hostID() throws -> String {
        _ = try signingKey()
        return BrowserCrypto.hash(Data(token.utf8))
    }

    func publicKey() throws -> String {
        try signingKey().publicKey.x963Representation.base64EncodedString()
    }
}

struct BrowserPeerRecord: Codable, Equatable {
    var version = 1
    var peerID: String
    var publicKey: String
    var origin: String
    var maximumMode: String
    var display: String
    var approvedAt: String
    var revoked = false

    func validate() throws {
        guard version == 1,
              BrowserPeerValidation.isToken(peerID),
              BrowserPeerValidation.isPublicSigningKey(publicKey),
              BrowserPeerValidation.isOrigin(origin),
              BrowserPeerValidation.isMode(maximumMode),
              !display.isEmpty,
              display.utf8.count <= 256,
              BrowserPeerValidation.isDecimal(approvedAt),
              !revoked else {
            throw BrowserPeerStoreError.invalidRecord
        }
    }
}

enum BrowserPeerValidation {
    static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

    static func isToken(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == "0" || value.first != "0",
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(value) else { return false }
        return number <= maximumSafeInteger
    }

    static func isMode(_ value: String) -> Bool {
        value == "view" || value == "interactive"
    }

    static func mode(_ requested: String, isAllowedBy maximum: String) -> Bool {
        isMode(requested) && isMode(maximum) && (requested == "view" || maximum == "interactive")
    }

    static func isOrigin(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              (url.path.isEmpty || url.path == "/"),
              let host = url.host,
              !host.isEmpty else { return false }
        return url.scheme == "https" || (url.scheme == "http" && isLoopback(host))
    }

    static func isBrowserHostURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/browser-host",
              let host = url.host,
              !host.isEmpty else { return false }
        return url.scheme == "wss" || (url.scheme == "ws" && isLoopback(host))
    }

    static func origin(forBrowserHostURL value: String) -> String? {
        guard isBrowserHostURL(value),
              let url = URL(string: value) else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme == "wss" ? "https" : "http"
        components.host = url.host
        components.port = url.port
        components.path = ""
        return components.string
    }

    static func isPublicSigningKey(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value),
              data.count == 65,
              data.base64EncodedString() == value else { return false }
        return (try? P256.Signing.PublicKey(x963Representation: data)) != nil
    }

    static func isPublicAgreementKey(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value),
              data.count == 65,
              data.base64EncodedString() == value else { return false }
        return (try? P256.KeyAgreement.PublicKey(x963Representation: data)) != nil
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}

enum BrowserPeerStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .keychain:
            "Browser trust could not be saved in Keychain. Unlock this Mac and try again."
        case .invalidRecord:
            "Saved browser trust is invalid. Revoke it and enroll the browser again."
        }
    }
}

struct BrowserPeerStoreBackend {
    var read: (_ account: String) throws -> Data?
    var write: (_ account: String, _ data: Data) throws -> Void
    var delete: (_ account: String) throws -> Void

    static let keychain = BrowserPeerStoreBackend(
        read: { account in
            var query = BrowserPeerStore.query(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var output: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &output)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = output as? Data else {
                throw BrowserPeerStoreError.keychain(status)
            }
            return data
        },
        write: { account, data in
            let query = BrowserPeerStore.query(account: account)
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                updates.forEach { add[$0.key] = $0.value }
                let result = SecItemAdd(add as CFDictionary, nil)
                guard result == errSecSuccess else { throw BrowserPeerStoreError.keychain(result) }
            } else if status != errSecSuccess {
                throw BrowserPeerStoreError.keychain(status)
            }
        },
        delete: { account in
            let status = SecItemDelete(BrowserPeerStore.query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw BrowserPeerStoreError.keychain(status)
            }
        }
    )
}

struct BrowserPeerStore {
    static let service = "PocketDesk.Browser.Trust.v1"
    static let identityAccount = "host-signing-identity"
    static let peerAccount = "approved-browser-peer"

    private let backend: BrowserPeerStoreBackend

    init(backend: BrowserPeerStoreBackend = .keychain) {
        self.backend = backend
    }

    func loadOrCreateIdentity() throws -> BrowserHostIdentity {
        if let data = try backend.read(Self.identityAccount) {
            let identity = try decode(BrowserHostIdentity.self, from: data)
            _ = try identity.signingKey()
            return identity
        }
        let identity = try BrowserHostIdentity.create()
        try backend.write(Self.identityAccount, try JSONEncoder().encode(identity))
        return identity
    }

    func loadPeer() throws -> BrowserPeerRecord? {
        guard let data = try backend.read(Self.peerAccount) else { return nil }
        let peer = try decode(BrowserPeerRecord.self, from: data)
        try peer.validate()
        return peer
    }

    func savePeer(_ peer: BrowserPeerRecord) throws {
        try peer.validate()
        try backend.write(Self.peerAccount, try JSONEncoder().encode(peer))
    }

    func deletePeer() throws {
        try backend.delete(Self.peerAccount)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BrowserPeerStoreError.invalidRecord
        }
    }

    fileprivate static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
