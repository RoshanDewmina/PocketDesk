import Foundation
import WidgetKit

/// Keeps the Connect widget's snapshot in step with what this app observed, and asks WidgetKit to
/// redraw only when the stored snapshot changed.
@MainActor
final class MacWidgetSync {
    static let shared = MacWidgetSync()

    /// A repeated observation of the same presence refreshes its time at most this often.
    static let refreshInterval: TimeInterval = 5 * 60

    var defaults: UserDefaults? = MacWidgetSnapshot.sharedDefaults
    var reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: ConnectWidgetLink.kind) }
    var now: () -> Date = { Date() }
    var lastReached: () -> Date? = { LastReached.date() }

    /// Only facts the app saw: a live session, the Mac's own departure report, or a failed attempt.
    static func observedPresence(connected: Bool, departure: HostPresence?,
                                 failure: FriendlyError.Kind?) -> MacWidgetSnapshot.Presence? {
        if connected { return .awake }
        switch departure {
        case .sleeping?: return .asleep
        case .locked?: return .locked
        case .switchedUser?: return .otherUser
        case .displayAsleep?, nil: break
        }
        switch failure {
        case .unreachable?, .connectionLost?: return .notAnswering
        case .screenRecordingOff?: return .screenRecordingOff
        case .screenRecordingApproval?: return .screenRecordingApproval
        default: return nil
        }
    }

    static func presence(for outcome: MacReachabilityProbe.Outcome) -> MacWidgetSnapshot.Presence? {
        switch outcome {
        case .answering: .awake
        case .notAnswering: .notAnswering
        case .sessionBusy, .serviceUnreachable: nil
        }
    }

    /// Nil clears the widget. A new observation replaces the presence; none keeps the last one for this Mac.
    static func next(previous: MacWidgetSnapshot?, macName: String?, observed: MacWidgetSnapshot.Presence?,
                     now: Date, lastReached: Date?) -> MacWidgetSnapshot? {
        guard let macName, !macName.isEmpty else { return nil }
        let kept = previous?.macName == macName ? previous : nil
        var presence = kept?.presence
        var presenceAt = kept?.presenceAt
        if let observed {
            let fresh = observed == presence && presenceAt.map { now.timeIntervalSince($0) < refreshInterval } == true
            if !fresh { presenceAt = now }
            presence = observed
        }
        return MacWidgetSnapshot(macName: macName, presence: presence, presenceAt: presenceAt, lastReached: lastReached)
    }

    func update(macName: String?, observed: MacWidgetSnapshot.Presence?) {
        let next = Self.next(previous: MacWidgetSnapshot.load(from: defaults), macName: macName, observed: observed,
                             now: now(), lastReached: lastReached())
        if MacWidgetSnapshot.store(next, in: defaults) { reload() }
    }
}
