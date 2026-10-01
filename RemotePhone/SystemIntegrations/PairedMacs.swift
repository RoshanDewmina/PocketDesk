import Foundation

/// A Mac this iPhone is paired with, as the system surfaces (Siri, Shortcuts, Spotlight) see it.
/// Each surface resolves an explicit destination; legacy aliases remain lookup-only.
struct PairedMac: Equatable {
    /// Opaque and stable for one pairing. Never the room id, which the service knows.
    let id: String
    let name: String
    let invitation: PairInvitation?
    var legacyAliases: [String] = []
    var pairingRefreshNote: String? {
        guard let invitation, !invitation.hasOwnerLocalIdentity else { return nil }
        return invitation.ownerPairID == nil
            ? "Older pairing · re-pair for sharing and local access"
            : "Older pairing · re-pair for local access"
    }
}

/// Home selection is deliberate: saved records do not imply a selected destination.
enum SavedMacHomeState: Equatable {
    case empty, choose, selected
    init(selected: PairInvitation?, saved: [PairedMac]) {
        self = selected != nil ? .selected : saved.isEmpty ? .empty : .choose
    }
}

enum PairedMacs {
    /// Replaced by tests. Reads the Keychain by default, so it needs an unlocked device, which is
    /// exactly when the intents that use it are allowed to run.
    static var loader: () -> [PairedMac] = defaultLoader

    static func all() -> [PairedMac] { loader() }

    static func mac(withID id: String) -> PairedMac? {
        all().first { $0.id == id || $0.legacyAliases.contains(id) }
    }

    static func id(for invitation: PairInvitation) -> String? {
        // Exact owner credentials bind alerts/activity/share destinations to one saved pair.
        all().first { $0.invitation?.room == invitation.room && $0.invitation?.token == invitation.token
            && $0.invitation?.durableHostID == invitation.durableHostID
            && $0.invitation?.ownerPairID == invitation.ownerPairID }?.id
    }

    static func mac(notificationIdentity: String) -> PairedMac? {
        all().first { $0.invitation?.notificationIdentity == notificationIdentity }
    }

    static func matching(ids: [String]) -> [PairedMac] {
        all().filter { mac in ids.contains { mac.id == $0 || mac.legacyAliases.contains($0) } }
    }

    static func opaqueID(room: String) -> String {
        "m_" + String(SecureRandom.digest("farside.mac|" + room).prefix(16))
    }

    private static func defaultLoader() -> [PairedMac] {
        #if DEBUG
        if let saved = DebugLaunchSeeds.invitation {
            return [PairedMac(id: opaqueID(room: saved.room), name: saved.name, invitation: saved)]
        }
        #endif
        guard let snapshot = try? PhoneTrustStore.shared.snapshot() else { return [] }
        return snapshot.hosts.map { PairedMac(id: "m_" + $0.id, name: $0.invitation.name, invitation: $0.invitation, legacyAliases: $0.legacyAliases) }
    }
}

/// The last time this phone reached each Mac, keyed by a digest of the Mac's room.
enum LastReached {
    static let defaultsKey = "lastReachedByMac"
    static let legacyDefaultsKey = "lastReachedAt"

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-reached|" + room).prefix(24)) }

    static func date(room: String?, in defaults: UserDefaults = .standard) -> Date? {
        guard let room, let stamp = all(in: defaults)[macKey(room: room)], stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    static func record(_ date: Date, room: String?, in defaults: UserDefaults = .standard) {
        guard let room else { return }
        var stamps = all(in: defaults)
        stamps[macKey(room: room)] = date.timeIntervalSince1970
        defaults.set(stamps, forKey: defaultsKey)
    }

    static func forget(room: String, in defaults: UserDefaults = .standard) {
        var stamps = all(in: defaults)
        guard stamps.removeValue(forKey: macKey(room: room)) != nil else { return }
        defaults.set(stamps, forKey: defaultsKey)
    }

    /// The single pre-per-Mac stamp was written by the last Mac reached, which is almost always the
    /// selected one, so it moves to that Mac once instead of disappearing.
    static func adoptLegacy(room: String?, in defaults: UserDefaults = .standard) {
        let legacy = defaults.double(forKey: legacyDefaultsKey)
        guard legacy > 0, let room else { return }
        defaults.removeObject(forKey: legacyDefaultsKey)
        if date(room: room, in: defaults) == nil { record(Date(timeIntervalSince1970: legacy), room: room, in: defaults) }
    }

    private static func all(in defaults: UserDefaults) -> [String: Double] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    /// "11:48 PM", "yesterday 11:48 PM" or "Sep 27": short enough to speak.
    static func spoken(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
