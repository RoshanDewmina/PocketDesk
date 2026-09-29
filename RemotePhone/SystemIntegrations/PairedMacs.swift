import Foundation

/// A Mac this iPhone is paired with, as the system surfaces (Siri, Shortcuts, Spotlight) see it.
/// Farside 1.0 pairs one Mac at a time, but every surface is written for several: the intents take
/// an optional Mac and ask "Which Mac?" only when there is more than one.
struct PairedMac: Equatable {
    /// Opaque and stable for one pairing. Never the room id, which the service knows.
    let id: String
    let name: String
    let invitation: PairInvitation?
}

enum PairedMacs {
    /// Replaced by tests. Reads the Keychain by default, so it needs an unlocked device, which is
    /// exactly when the intents that use it are allowed to run.
    static var loader: () -> [PairedMac] = defaultLoader

    static func all() -> [PairedMac] { loader() }

    static func mac(withID id: String) -> PairedMac? { all().first { $0.id == id } }

    static func opaqueID(room: String) -> String {
        "m_" + String(SecureRandom.digest("farside.mac|" + room).prefix(16))
    }

    private static func defaultLoader() -> [PairedMac] {
        var saved: PairInvitation?
        #if DEBUG
        saved = DebugLaunchSeeds.invitation
        #endif
        if saved == nil { saved = (try? PairStore(account: "phone").read(PairInvitation.self)) ?? nil }
        guard let saved else { return [] }
        return [PairedMac(id: opaqueID(room: saved.room), name: saved.name, invitation: saved)]
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
