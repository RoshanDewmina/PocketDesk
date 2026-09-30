import Foundation

/// A locally indexed owner pairing. Legacy records have no proven durable host identity;
/// their random index and historical system-surface alias are lookup keys only.
struct PhoneHostTrust: Codable, Equatable, Identifiable {
    let id: String
    var durableHostID: String?
    var ownerPairID: String?
    var invitation: PairInvitation
    var legacyAliases: [String]
}

struct PhoneTrustSnapshot: Codable, Equatable {
    var version = 2
    var hosts: [PhoneHostTrust] = []
    var selectedHostID: String?
    // A persisted empty snapshot is authoritative; it must never resurrect the v1 backup.
    func validate() throws {
        guard version == 2, hosts.count <= 32,
              Set(hosts.map(\.id)).count == hosts.count,
              selectedHostID == nil || hosts.contains(where: { $0.id == selectedHostID }) else {
            throw RemoteError.invalidPairing
        }
        var identities = Set<String>()
        var rooms = Set<String>()
        var aliases = Set<String>()
        for host in hosts {
            guard SecureRandom.isToken(host.id), host.legacyAliases.count <= 8,
                  rooms.insert(host.invitation.room).inserted else { throw RemoteError.invalidPairing }
            for alias in host.legacyAliases {
                guard alias.hasPrefix("m_"), alias.count == 18,
                      SecureRandom.isToken(String(repeating: String(alias.dropFirst(2)), count: 4)),
                      aliases.insert(alias).inserted else { throw RemoteError.invalidPairing }
            }
            try host.invitation.validate(enrollment: false)
            if let identity = host.durableHostID {
                guard SecureRandom.isToken(identity), identities.insert(identity).inserted,
                      host.invitation.durableHostID == identity else { throw RemoteError.invalidPairing }
            } else if host.invitation.durableHostID != nil { throw RemoteError.invalidPairing }
            guard host.ownerPairID == host.invitation.ownerPairID else { throw RemoteError.invalidPairing }
        }
    }
    var selected: PhoneHostTrust? { hosts.first { $0.id == selectedHostID } }
}

/// Every mutation replaces ONE Keychain item. There is no partially-written host/index/selection
/// transaction. The old single-pair item remains a rollback backup until that pair is forgotten.
/// All in-process readers/writers share this lock, including Siri/system-surface loaders.
final class PhoneTrustStore {
    static let shared = PhoneTrustStore()
    private static let lock = NSRecursiveLock()
    private let records: any PairPersistence
    private let legacy: any PairPersistence

    init(records: any PairPersistence = PairStore(account: "phone.hosts.v2"),
         legacy: any PairPersistence = PairStore(account: "phone")) {
        self.records = records; self.legacy = legacy
    }

    func snapshot() throws -> PhoneTrustSnapshot {
        try locked { try load() }
    }

    func select(hostID: String) throws {
        try locked {
            var next = try load()
            guard next.hosts.contains(where: { $0.id == hostID }) else { throw RemoteError.invalidPairing }
            next.selectedHostID = hostID
            try commit(next)
        }
    }

    /// Only call after the existing owner-approval handshake accepted and rotated the invitation.
    /// Enrollment must not implicitly overwrite the selected host when a different Mac approves.
    func saveApproved(_ invitation: PairInvitation) throws {
        try locked {
            try invitation.validate(enrollment: false)
            var next = try load()
            // Reusing a room must not move credentials across an identified host.
            if let collision = next.hosts.first(where: { $0.invitation.room == invitation.room }),
               let known = collision.durableHostID, known != invitation.durableHostID {
                throw RemoteError.invalidPairing
            }
            let index: Int?
            if let durableID = invitation.durableHostID {
                index = next.hosts.firstIndex { $0.durableHostID == durableID }
                    ?? next.hosts.firstIndex { $0.durableHostID == nil && $0.invitation.room == invitation.room }
            } else {
                index = next.hosts.firstIndex { $0.durableHostID == nil && $0.invitation.room == invitation.room }
            }
            if let index {
                // A legacy packet can never downgrade an identified host.
                var host = next.hosts[index]
                host.invitation = invitation
                host.durableHostID = invitation.durableHostID
                host.ownerPairID = invitation.ownerPairID
                next.hosts[index] = host
                next.selectedHostID = host.id
            } else {
                guard next.hosts.count < 32 else { throw RemoteError.invalidPairing }
                let host = try Self.record(invitation)
                next.hosts.append(host)
                next.selectedHostID = host.id
            }
            try commit(next)
        }
    }

    /// No auto-selection after forgetting: a queued connect can never steer a different Mac.
    /// Deletion of an old rollback backup must succeed before removing its v2 authority.
    func forget(hostID: String) throws {
        try locked {
            var next = try load()
            guard let host = next.hosts.first(where: { $0.id == hostID }) else { return }
            if let backup = try legacy.read(PairInvitation.self),
               (backup.room == host.invitation.room && backup.server == host.invitation.server)
                || host.legacyAliases.contains(Self.legacyAlias(room: backup.room)) {
                try legacy.delete()
                guard try legacy.read(PairInvitation.self) == nil else { throw RemoteError.invalidPairing }
            }
            next.hosts.removeAll { $0.id == hostID }
            if next.selectedHostID == hostID { next.selectedHostID = nil }
            try commit(next)
        }
    }

    private func load() throws -> PhoneTrustSnapshot {
        // Read/decode/version failures propagate. Fallback is ONLY for an absent v2 item.
        if let existing = try records.read(PhoneTrustSnapshot.self) {
            try existing.validate(); return existing
        }
        var migrated = PhoneTrustSnapshot()
        if let old = try legacy.read(PairInvitation.self) {
            try old.validate(enrollment: false)
            let host = try Self.record(old)
            migrated.hosts = [host]; migrated.selectedHostID = host.id
        }
        try commit(migrated)
        return migrated
    }

    private func commit(_ snapshot: PhoneTrustSnapshot) throws {
        try snapshot.validate()
        try records.save(snapshot)
        guard try records.read(PhoneTrustSnapshot.self) == snapshot else { throw RemoteError.invalidPairing }
    }

    private static func record(_ invitation: PairInvitation) throws -> PhoneHostTrust {
        PhoneHostTrust(id: try SecureRandom.token(), durableHostID: invitation.durableHostID,
                       ownerPairID: invitation.ownerPairID, invitation: invitation,
                       legacyAliases: [legacyAlias(room: invitation.room)])
    }
    static func legacyAlias(room: String) -> String {
        "m_" + String(SecureRandom.digest("farside.mac|" + room).prefix(16))
    }
    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }; return try operation()
    }
}

/// Compatibility adapter: coordinator persistence continues to read/save PairInvitation,
/// while the authoritative storage contains all hosts. Inject the SAME instance into phone/UI.
struct PhonePairPersistence: PairPersistence {
    let trust: PhoneTrustStore
    init(trust: PhoneTrustStore = .shared) { self.trust = trust }
    func save<T: Encodable>(_ value: T) throws {
        guard let invitation = value as? PairInvitation else { throw RemoteError.invalidPairing }
        try trust.saveApproved(invitation)
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        guard type == PairInvitation.self else { throw RemoteError.invalidPairing }
        return try trust.snapshot().selected?.invitation as? T
    }
    func delete() throws {
        if let selected = try trust.snapshot().selectedHostID { try trust.forget(hostID: selected) }
    }
}
