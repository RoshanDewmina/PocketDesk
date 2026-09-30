import Foundation
import CryptoKit

struct GuestSignalEnvelope: Codable, Equatable, Sendable {
    let direction: String
    let sequence: String
    let payload: String
}

enum GuestCrypto {
    static let domain = "Farside/guest/1"
    static let maximumSignalBytes = 131_072
    static let maximumSequence: UInt64 = 9_007_199_254_740_991

    static func canonical(_ fields: [String]) -> Data {
        var data = Data()
        for value in [domain] + fields {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sign(_ fields: [String], key: P256.Signing.PrivateKey) throws -> String {
        guard fields.count <= 32, fields.allSatisfy({ $0.utf8.count <= 4096 }) else { throw GuestValidation.Failure.invalidMessage }
        return try key.signature(for: canonical(fields)).rawRepresentation.base64EncodedString()
    }
    static func verify(_ fields: [String], signature: String, publicKey: String) -> Bool {
        guard fields.count <= 32, fields.allSatisfy({ $0.utf8.count <= 4096 }), GuestValidation.publicKey(publicKey),
              let rawKey = Data(base64Encoded: publicKey), let rawSignature = Data(base64Encoded: signature),
              rawSignature.count == 64, rawSignature.base64EncodedString() == signature,
              let key = try? P256.Signing.PublicKey(x963Representation: rawKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature) else { return false }
        return key.isValidSignature(sig, for: canonical(fields))
    }
    static func sharedKey(privateKey: P256.KeyAgreement.PrivateKey, publicKey: String, grant: GuestGrant) throws -> SymmetricKey {
        guard GuestValidation.publicKey(publicKey), let raw = Data(base64Encoded: publicKey) else { throw GuestValidation.Failure.invalidMessage }
        let other = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: other)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: canonical(grant.signedFields))),
            sharedInfo: Data("Farside/guest/1/signaling".utf8), outputByteCount: 32)
    }
    private static func parameters(grantID: String, sessionID: String, direction: String, sequence: UInt64) throws -> (AES.GCM.Nonce, Data) {
        guard GuestValidation.token(grantID), GuestValidation.token(sessionID), ["host", "guest"].contains(direction),
              sequence > 0, sequence <= maximumSequence else { throw GuestValidation.Failure.invalidMessage }
        var nonce = Data(), prefix = UInt32(direction == "host" ? 1 : 2).bigEndian, count = sequence.bigEndian
        withUnsafeBytes(of: &prefix) { nonce.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { nonce.append(contentsOf: $0) }
        return (try AES.GCM.Nonce(data: nonce), canonical(["signal", grantID, sessionID, direction, String(sequence)]))
    }
    static func seal(_ data: Data, key: SymmetricKey, grantID: String, sessionID: String, direction: String, sequence: UInt64) throws -> GuestSignalEnvelope {
        guard data.count <= maximumSignalBytes else { throw GuestValidation.Failure.invalidMessage }
        let (nonce, aad) = try parameters(grantID: grantID, sessionID: sessionID, direction: direction, sequence: sequence)
        let box = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: aad)
        return GuestSignalEnvelope(direction: direction, sequence: String(sequence), payload: (box.ciphertext + box.tag).base64EncodedString())
    }
    static func open(_ envelope: GuestSignalEnvelope, key: SymmetricKey, grantID: String, sessionID: String, direction: String) throws -> Data {
        guard envelope.direction == direction, let sequence = UInt64(envelope.sequence), String(sequence) == envelope.sequence,
              let bytes = Data(base64Encoded: envelope.payload), bytes.count >= 16, bytes.count <= maximumSignalBytes + 16,
              bytes.base64EncodedString() == envelope.payload else { throw GuestValidation.Failure.invalidMessage }
        let (nonce, aad) = try parameters(grantID: grantID, sessionID: sessionID, direction: direction, sequence: sequence)
        return try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes.dropLast(16), tag: bytes.suffix(16)), using: key, authenticating: aad)
    }
}
