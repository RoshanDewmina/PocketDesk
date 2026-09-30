import Foundation

/// A Mac this iPhone is paired with, as the system surfaces (Siri, Shortcuts, Spotlight) see it.
/// Each surface resolves an explicit destination; legacy aliases remain lookup-only.
struct PairedMac: Equatable {
    /// Opaque and stable for one pairing. Never the room id, which the service knows.
    let id: String
    let name: String
    let invitation: PairInvitation?
    var legacyAliases: [String] = []
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
            && $0.invitation?.durableHostID == invitation.durableHostID }?.id
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

/// The last time this phone reached its Mac, as the Home card records it.
enum LastReached {
    static func date(in defaults: UserDefaults = .standard) -> Date? {
        let stamp = defaults.double(forKey: HomeView.lastReachedKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
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
