import Combine
import Foundation

/// What the phone is doing on this Mac, for the popover's activity lights (D39). Pointer movement
/// is left out on purpose: it would keep the lights on permanently.
enum HostActivityKind: String, CaseIterable, Identifiable {
    case tap, keys, scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: "Taps"
        case .keys: "Keys"
        case .scroll: "Scroll"
        }
    }

    /// Only accepted input counts; the caller records after the input driver accepted it.
    init?(action: String) {
        switch action {
        case "click", "right", "middle", "double", "dragDown": self = .tap
        case "text", "key": self = .keys
        case "scroll": self = .scroll
        default: return nil
        }
    }
}

struct HostActivityPulse: Equatable {
    var serial: Int
    var date: Date
}

/// A small, throttled feed of the live session for the popover and the menu-bar mark: activity
/// pulses (at most 10 a second per kind), the last few taps for the strip's ripples, and measured
/// round trips for the sparkline. Separate from `HostViewState` so input never re-renders Settings.
@MainActor
final class HostActivityFeed: ObservableObject {
    static let throttle: TimeInterval = 0.1
    static let roundTripLimit = 40
    static let tapLimit = 6

    @Published private(set) var pulses: [HostActivityKind: HostActivityPulse] = [:]
    @Published private(set) var recentTaps: [Date] = []
    @Published private(set) var tapSerial = 0
    @Published private(set) var roundTrips: [Int] = []

    func record(action: String, at date: Date = Date()) {
        guard let kind = HostActivityKind(action: action) else { return }
        if let last = pulses[kind], date.timeIntervalSince(last.date) < Self.throttle { return }
        pulses[kind] = HostActivityPulse(serial: (pulses[kind]?.serial ?? 0) + 1, date: date)
        guard kind == .tap else { return }
        tapSerial += 1
        recentTaps = Array((recentTaps + [date]).suffix(Self.tapLimit))
    }

    /// A measured round trip; unmeasured readouts add nothing, so the sparkline never guesses.
    func record(roundTripMs: Int?) {
        guard let roundTripMs, roundTripMs >= 0 else { return }
        roundTrips = Array((roundTrips + [roundTripMs]).suffix(Self.roundTripLimit))
    }

    func reset() {
        pulses = [:]
        recentTaps = []
        roundTrips = []
    }
}
