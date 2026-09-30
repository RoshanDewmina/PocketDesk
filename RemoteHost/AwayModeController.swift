import Foundation

@MainActor
protocol AwayModeHost: AnyObject {
    /// Everything except power and managed-Mac state, which the controller reads itself.
    func awayConditions() -> AwayConditions
    func awayStateChanged()
    func awayRecord(_ message: String)
}

@MainActor
protocol AwayTicking: AnyObject {
    func start(interval: TimeInterval, _ fire: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class TimerAwayTicker: AwayTicking {
    func start(interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) {}
    func stop() {}
}

@MainActor
final class AwayModeController {
    static let tickInterval: TimeInterval = 0.5

    struct Dependencies {
        var locker: HostScreenLocking
        var power: HostPowerSourceReading
        var isManaged: () -> Bool
        var inputMonitor: AwayInputMonitoring
        var ticker: AwayTicking
        var now: () -> TimeInterval
        var wallClock: () -> Date
    }

    weak var host: AwayModeHost?
    private(set) var machine = AwayModeMachine()
    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var wantsCover: Bool { false }
    var holdsDisplayAwake: Bool { false }
    var protocolState: AwayModeState { .off }
    /// True while Farside itself asked macOS to lock, so the lock is not reported as unexpected.
    var lockRequestedByFarside: Bool { false }

    func readout(available: Bool) -> HostAwayReadout { HostAwayReadout(available: available) }

    func refresh() {}
    func tick() {}
    func localInput() {}
    func coverNow() {}
    func turnOffAtMac() {}
    func end(_ reason: AwayEndReason) {}
    func lockForQuit() {}
    func lockFirstAfterRelaunch() {}
}
