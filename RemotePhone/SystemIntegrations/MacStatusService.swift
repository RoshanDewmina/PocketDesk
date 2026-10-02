import Foundation

/// Answers "Is my Mac awake?" in plain words without starting a session.
///
/// Honesty rules, from the spec: only an answer from the Mac's Farside counts as "awake"; a silence
/// is "not answering", never "asleep", because the service cannot tell a sleeping Mac from an offline
/// one, or from a removed pairing. Siri copy is plain on purpose: no app name, no jokes.
@MainActor
final class MacStatusService {
    static let shared = MacStatusService()

    enum State: String, Equatable {
        case connected, connecting, awake, notAnswering, busy, unreachable
    }

    struct Report: Equatable {
        var state: State
        var spoken: String
    }

    /// What this app itself is doing with the Mac. The app installs it once its model exists; a process
    /// the system launched just for the intent has no session at all.
    var currentSession: () -> (connected: Bool, running: Bool) = { (false, false) }
    var makeProbe: () -> MacReachabilityProbe = { MacReachabilityProbe() }
    var lastReached: (PairedMac) -> Date? = { LastReached.date(room: $0.invitation?.room) }
    var now: () -> Date = { Date() }

    func report(for mac: PairedMac) async -> Report {
        let session = currentSession()
        if session.connected { return Report(state: .connected, spoken: "You are connected to \(mac.name) right now.") }
        if session.running { return Report(state: .connecting, spoken: "Connecting to \(mac.name) right now.") }
        #if DEBUG
        if let forced = LaunchOptions.value("--ui-mac-status="), let outcome = Self.forcedOutcome(forced) {
            return report(for: mac, outcome: outcome)
        }
        #endif
        guard let invitation = mac.invitation else { return report(for: mac, outcome: .serviceUnreachable) }
        return report(for: mac, outcome: await makeProbe().check(invitation))
    }

    func report(for mac: PairedMac, outcome: MacReachabilityProbe.Outcome) -> Report {
        switch outcome {
        case .answering:
            return Report(state: .awake, spoken: "\(mac.name) answered just now and looks awake.")
        case .notAnswering:
            let tail = "It may be asleep, off or offline."
            if let last = lastReached(mac) {
                return Report(state: .notAnswering,
                              spoken: "I have not heard from \(mac.name) since \(LastReached.spoken(last, now: now())). \(tail)")
            }
            return Report(state: .notAnswering, spoken: "I could not reach \(mac.name). \(tail)")
        case .sessionBusy:
            return Report(state: .busy, spoken: "\(mac.name) still has a session open. Try again in a moment.")
        case .serviceUnreachable:
            return Report(state: .unreachable,
                          spoken: "I could not reach the connection service. Check that this \(DeviceWord.current) is online.")
        }
    }

    #if DEBUG
    private static func forcedOutcome(_ name: String) -> MacReachabilityProbe.Outcome? {
        switch name {
        case "awake": .answering
        case "notAnswering": .notAnswering
        case "busy": .sessionBusy
        case "unreachable": .serviceUnreachable
        default: nil
        }
    }
    #endif
}
