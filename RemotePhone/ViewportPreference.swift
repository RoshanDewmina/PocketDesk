import Foundation

/// Remembers whether the desktop fills the screen or fits inside the safe area.
enum ViewportPreference {
    static let key = "viewportMode"

    static func stored(in defaults: UserDefaults = .standard) -> ViewportMode {
        defaults.string(forKey: key).flatMap(ViewportMode.init(rawValue:)) ?? .fill
    }

    static func store(_ mode: ViewportMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

/// G4: when the phone tells the Mac which part of the desktop it shows. The newest request rides on
/// every regular heartbeat, so a restarted Mac re-applies it; a change also leaves on a heartbeat of its
/// own, at once when a gesture settles and otherwise at most every 100 ms. Each change sent takes the
/// next epoch; an unchanged request keeps its epoch.
struct ViewportReporter {
    static let minimumInterval: TimeInterval = 0.1

    enum Send: Equatable {
        case none
        case now
        case at(TimeInterval)
    }

    private(set) var request: ViewportCaptureRequest?
    private(set) var epoch: UInt64 = 0
    private var sent: ViewportCaptureRequest?
    private var lastSentAt = -TimeInterval.infinity

    var hasUnsentChange: Bool { request != nil && request != sent }

    mutating func update(_ request: ViewportCaptureRequest?) {
        self.request = request
    }

    /// When the newest request should leave on its own heartbeat.
    func nextSend(settled: Bool, at now: TimeInterval) -> Send {
        guard hasUnsentChange else { return .none }
        let due = lastSentAt + Self.minimumInterval
        return settled || now >= due ? .now : .at(due)
    }

    /// The region for a heartbeat leaving now; nil while the request belongs to another display.
    mutating func region(forDisplay displaySize: CGSize, at now: TimeInterval) -> ViewportRegion? {
        guard let request, request.displaySize == displaySize else { return nil }
        if request != sent {
            epoch += 1
            sent = request
        }
        lastSentAt = now
        return request.region(epoch: epoch)
    }

    /// A new session has been sent nothing, so its first heartbeat carries the request under a new epoch.
    mutating func sessionEnded() {
        sent = nil
        lastSentAt = -.infinity
    }
}
