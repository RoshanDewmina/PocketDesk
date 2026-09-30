import Foundation

struct HostIdentityRecord: Codable, Equatable {
    var version = 1
    let hostID: String
    let localServiceName: String

    func validate() throws {
        guard version == 1, SecureRandom.isToken(hostID),
              localServiceName.hasPrefix("farside-"), localServiceName.utf8.count == 40,
              FileTransferID.isValid(String(localServiceName.dropFirst(8))) else {
            throw RemoteError.invalidPairing
        }
    }
}

/// Independent of pairing records: replacing/removing a phone never replaces the Mac identity.
struct HostIdentityStore {
    let persistence: any PairPersistence

    init(persistence: any PairPersistence = PairStore(account: "host.identity.v1")) {
        self.persistence = persistence
    }

    func loadOrCreate() throws -> HostIdentityRecord {
        if let saved = try persistence.read(HostIdentityRecord.self) {
            try saved.validate()
            return saved
        }
        let value = HostIdentityRecord(hostID: try SecureRandom.token(),
                                       localServiceName: "farside-" + FileTransferID.make())
        try value.validate()
        try persistence.save(value)
        return value
    }
}
