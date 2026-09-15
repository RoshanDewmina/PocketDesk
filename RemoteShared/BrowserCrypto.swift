import Foundation
import CryptoKit

struct BrowserEnvelope: Codable {
    var sequence: String
    var direction: String
    var payload: String
}

enum BrowserCrypto {
    static func openEnrollment(secret: String, hostID: String, origin: String, nonce: String, payload: String) throws -> Data {
        guard SecureRandom.isToken(secret), SecureRandom.isToken(hostID),
              let nonceBytes = Data(base64Encoded: nonce), nonceBytes.count == 12, nonceBytes.base64EncodedString() == nonce,
              let bytes = Data(base64Encoded: payload), (16...1024).contains(bytes.count), bytes.base64EncodedString() == payload else { throw RemoteError.invalidMessage }
        let characters = Array(secret.utf8)
        var keyBytes = Data()
        for i in stride(from: 0, to: characters.count, by: 2) {
            guard let value = UInt8(String(decoding: characters[i...i+1], as: UTF8.self), radix: 16) else { throw RemoteError.invalidMessage }
            keyBytes.append(value)
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: canonical(["enroll", hostID, origin]))
    }
    static func canonical(_ fields: [String]) -> Data {
        var output = Data()
        for field in ["PocketDesk/browser/1"] + fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(bytes)
        }
        return output
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func random() throws -> String { try SecureRandom.token() }
    static func sign(_ fields: [String], key: P256.Signing.PrivateKey) throws -> String {
        try key.signature(for: canonical(fields)).rawRepresentation.base64EncodedString()
    }
    static func verify(_ fields: [String], signature: String, publicKey: String) -> Bool {
        guard fields.count <= 32, fields.allSatisfy({ $0.utf8.count <= 262144 }),
              let raw = Data(base64Encoded: publicKey), raw.count == 65, raw.first == 4,
              let sig = Data(base64Encoded: signature), sig.count == 64,
              raw.base64EncodedString() == publicKey, sig.base64EncodedString() == signature,
              let key = try? P256.Signing.PublicKey(x963Representation: raw),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { return false }
        return key.isValidSignature(signature, for: canonical(fields))
    }
    static func sharedKey(privateKey: P256.KeyAgreement.PrivateKey, publicKey: String, challenge: [String]) throws -> SymmetricKey {
        guard let raw = Data(base64Encoded: publicKey), raw.count == 65, raw.first == 4, raw.base64EncodedString() == publicKey else { throw RemoteError.invalidMessage }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: canonical(challenge))), sharedInfo: Data("PocketDesk/browser/1/signaling".utf8), outputByteCount: 32)
    }
    private static func parameters(session: String, direction: String, sequence: UInt64, challengeHash: String) throws -> (AES.GCM.Nonce, Data) {
        guard SecureRandom.isToken(session), SecureRandom.isToken(challengeHash), ["host", "browser"].contains(direction), sequence > 0, sequence <= 9007199254740991 else { throw RemoteError.invalidMessage }
        var bytes = Data(); var prefix = UInt32(direction == "host" ? 1 : 2).bigEndian; var count = sequence.bigEndian
        withUnsafeBytes(of: &prefix) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        return (try AES.GCM.Nonce(data: bytes), canonical(["signal", session, direction, String(sequence), challengeHash]))
    }
    static func seal(_ signal: MediaSignal, key: SymmetricKey, session: String, direction: String, sequence: UInt64, challengeHash: String) throws -> BrowserEnvelope {
        let bytes = try JSONEncoder().encode(signal); guard bytes.count <= 131072 else { throw RemoteError.invalidMessage }
        let (nonce, aad) = try parameters(session: session, direction: direction, sequence: sequence, challengeHash: challengeHash)
        let box = try AES.GCM.seal(bytes, using: key, nonce: nonce, authenticating: aad)
        return BrowserEnvelope(sequence: String(sequence), direction: direction, payload: (box.ciphertext + box.tag).base64EncodedString())
    }
    static func open(_ envelope: BrowserEnvelope, key: SymmetricKey, session: String, direction: String, challengeHash: String) throws -> MediaSignal {
        guard envelope.direction == direction, let sequence = UInt64(envelope.sequence), String(sequence) == envelope.sequence,
              let bytes = Data(base64Encoded: envelope.payload), bytes.count >= 16, bytes.count <= 131088, bytes.base64EncodedString() == envelope.payload else { throw RemoteError.invalidMessage }
        let (nonce, aad) = try parameters(session: session, direction: direction, sequence: sequence, challengeHash: challengeHash)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        return try JSONDecoder().decode(MediaSignal.self, from: AES.GCM.open(box, using: key, authenticating: aad))
    }
}
