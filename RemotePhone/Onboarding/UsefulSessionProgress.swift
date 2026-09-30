import SwiftUI

/// Product guidance is local. Aggregate funnel counters are off until an explicit choice;
/// neither remote text, app names, host/grant IDs nor credentials are persisted in counters.
@MainActor final class UsefulSessionProgress: ObservableObject {
    @Published private(set) var evidence = UsefulSessionEvidence()
    @Published private(set) var consent: Bool
    @Published private(set) var counters: [String: Int]
    @Published var blocker = ""
    @Published private(set) var pictureConfirmationAvailable = false
    var onConfirmVisiblePicture: (() -> Void)?
    func setPictureConfirmationAvailable(_ value: Bool) {
        if pictureConfirmationAvailable != value { pictureConfirmationAvailable = value }
    }
    func confirmVisiblePicture() { onConfirmVisiblePicture?() }
    private let defaults: UserDefaults
    private var countedReadySessions: Set<UUID> = []
    private var lastReadyHost: String?
    private var lastReadySession: UUID?
    private var explicitlyEnded = false
    static let consentKey = "usefulSession.localCountersConsent.v1"
    static let countersKey = "usefulSession.localCounters.v1"
    static let counterNames: Set<String> = ["pictureReady", "couchReady", "appliedInput", "read", "navigate", "edit", "save", "reconnect", "return", "coachReplay", "support", "blocked"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let allowed = defaults.bool(forKey: Self.consentKey)
        consent = allowed
        let saved = allowed ? (defaults.dictionary(forKey: Self.countersKey) as? [String: Int] ?? [:]) : [:]
        counters = saved.filter { Self.counterNames.contains($0.key) && (0...1_000_000).contains($0.value) }
    }
    func setConsent(_ value: Bool) {
        consent = value; defaults.set(value, forKey: Self.consentKey)
        if !value { counters = [:]; defaults.removeObject(forKey: Self.countersKey) }
    }
    func count(_ key: String) {
        guard consent, Self.counterNames.contains(key) else { return }
        counters[key] = min((counters[key] ?? 0) + 1, 1_000_000)
        defaults.set(counters, forKey: Self.countersKey)
    }
    func admit(_ kind: UsefulSessionEvidence.Readiness, context: UsefulSessionContext, deadline: TimeInterval, now: TimeInterval) {
        evidence.admit(kind, context: context, deadline: deadline, now: now)
        guard evidence.ready(at: now), !countedReadySessions.contains(context.sessionID) else { return }
        if lastReadyHost == context.hostRecordID, lastReadySession != context.sessionID {
            count(explicitlyEnded ? "return" : "reconnect")
        }
        if countedReadySessions.count >= 64 { countedReadySessions.removeAll() }
        countedReadySessions.insert(context.sessionID)
        lastReadyHost = context.hostRecordID; lastReadySession = context.sessionID; explicitlyEnded = false
        count(kind == .picture ? "pictureReady" : "couchReady")
    }
    func invalidate(explicitEnd: Bool = false, pictureConfirmationAvailable: Bool = false) {
        evidence.invalidate()
        setPictureConfirmationAvailable(pictureConfirmationAvailable)
        if explicitEnd { explicitlyEnded = true }
    }
    func applied(context: UsefulSessionContext, now: TimeInterval) {
        let first = !evidence.appliedInput
        if evidence.applied(context: context, now: now), first { count("appliedInput") }
    }
    func confirm(_ outcome: UsefulSessionEvidence.Outcome, now: TimeInterval) {
        if evidence.confirm(outcome, now: now) { count(outcome.rawValue) }
    }
    func reportBlocker(_ value: String) {
        guard ["connection", "picture", "input", "task", "none"].contains(value) else { return }
        blocker = value; count("blocked")
    }
}
