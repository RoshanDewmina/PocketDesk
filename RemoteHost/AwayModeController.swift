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
    private var timer: Timer?
    private var fire: (@MainActor () -> Void)?

    func start(interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        stop()
        self.fire = fire
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire?() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fire = nil
    }
}

@MainActor
final class AwayModeController {
    static let tickInterval: TimeInterval = 0.5
    private static let notifyStep: TimeInterval = 5

    struct Dependencies {
        var locker: HostScreenLocking
        var power: HostPowerSourceReading
        var isManaged: () -> Bool
        var inputMonitor: AwayInputMonitoring
        var ticker: AwayTicking
        var now: () -> TimeInterval
        var wallClock: () -> Date
    }

    private struct Signature: Equatable {
        var phase: AwayPhase
        var wantsCover: Bool
        var holdsDisplayAwake: Bool
        var protocolState: AwayModeState
        var unavailable: AwayUnavailableReason?
        var lowPowerMode: Bool
        var coversAtStep: Int?
        var batteryEndsAtStep: Int?
    }

    weak var host: AwayModeHost?
    private(set) var machine = AwayModeMachine()
    private let dependencies: Dependencies
    private var lastConditions = AwayConditions()
    private var lastPower = HostPowerSnapshot()
    private var lockRequested = false
    private var wasArmed = false
    private var ticking = false
    private var quitting = false
    private var lastSignature: Signature?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var wantsCover: Bool { machine.wantsCover }
    var holdsDisplayAwake: Bool { machine.holdsDisplayAwake }
    var protocolState: AwayModeState { machine.protocolState }
    /// True while Farside itself asked macOS to lock, so the lock is not reported as unexpected.
    var lockRequestedByFarside: Bool { lockRequested }

    func readout(available: Bool) -> HostAwayReadout {
        let now = dependencies.now(), wall = dependencies.wallClock()
        return HostAwayReadout(available: available,
                               enabled: lastConditions.enabled,
                               phase: readoutPhase,
                               unavailable: unavailable,
                               coversAt: machine.coversIn(now: now).map { wall.addingTimeInterval($0) },
                               batteryEndsAt: machine.batteryEndsIn(now: now).map { wall.addingTimeInterval($0) },
                               lowPowerMode: lastPower.lowPowerMode)
    }

    func refresh() {
        var conditions = host?.awayConditions() ?? AwayConditions()
        let hostSawLock = conditions.screenLocked
        let power = dependencies.power.snapshot()
        conditions.onACPower = power.onACPower
        conditions.batteryPercent = power.batteryPercent
        conditions.managed = dependencies.isManaged()
        conditions.screenLocked = conditions.screenLocked || dependencies.locker.isScreenLocked()
        lastConditions = conditions
        lastPower = power
        apply(machine.update(conditions, now: dependencies.now()))
        // The host classifies its lock notification just before refreshing, and the machine may
        // already be off by then, so the lock stays ours until the host itself reports it.
        if hostSawLock && !isLocking { lockRequested = false }
        settle()
    }

    func tick() {
        refresh()
        apply(machine.tick(now: dependencies.now()))
        settle()
    }

    func localInput() {
        apply(machine.localInput(now: dependencies.now()))
        settle()
    }

    func coverNow() {
        machine.coverNow(now: dependencies.now())
        settle()
    }

    func turnOffAtMac() {
        machine.turnOffAtMac()
        settle()
    }

    func end(_ reason: AwayEndReason) {
        apply(machine.end(reason, now: dependencies.now()))
        settle()
    }

    func lockForQuit() {
        guard machine.phase != .off else { return }
        apply(machine.end(.quit, now: dependencies.now()))
        // Teardown after this still refreshes; nothing may restart watching a Mac that is quitting.
        quitting = true
        dependencies.inputMonitor.stop()
        dependencies.ticker.stop()
        ticking = false
    }

    func lockFirstAfterRelaunch() {
        apply(machine.end(.relaunchedAfterExit, now: dependencies.now()))
        settle()
    }

    private var isLocking: Bool {
        switch machine.phase {
        case .locking, .lockFailed: true
        case .off, .armedPresent, .armedCovered: false
        }
    }

    private var readoutPhase: HostAwayReadout.Phase {
        switch machine.phase {
        case .off: .off
        case .armedPresent: .armed
        case .armedCovered: .covered
        case .locking: .locking
        case .lockFailed: .lockFailed
        }
    }

    private var unavailable: AwayUnavailableReason? {
        lastConditions.enabled && machine.phase == .off ? AwayModeMachine.unavailableReason(lastConditions) : nil
    }

    private func apply(_ effect: AwayEffect?) {
        guard case .lock(let reason)? = effect else { return }
        lockRequested = true
        host?.awayRecord("Locking this Mac: \(reason.rawValue)")
        if !dependencies.locker.requestLock() {
            host?.awayRecord("Couldn’t send the lock shortcut")
        }
    }

    private func settle() {
        if machine.isArmed && !wasArmed { lockRequested = false }
        wasArmed = machine.isArmed

        let monitor = dependencies.inputMonitor
        if machine.phase != .off && !quitting {
            if !monitor.isRunning { monitor.start { [weak self] in self?.localInput() } }
        } else if monitor.isRunning {
            monitor.stop()
        }

        let wantsTicks = !quitting && (machine.phase != .off || lastConditions.enabled)
        if wantsTicks != ticking {
            ticking = wantsTicks
            if wantsTicks {
                dependencies.ticker.start(interval: Self.tickInterval) { [weak self] in self?.tick() }
            } else {
                dependencies.ticker.stop()
            }
        }

        let signature = currentSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        host?.awayStateChanged()
    }

    // Deadlines on the monotonic clock stay fixed between inputs, so ticks never move them;
    // stepping them means a stream of local input notifies the host at most once per step.
    private func currentSignature() -> Signature {
        let now = dependencies.now()
        let coversAt = machine.coversIn(now: now).map { _ in machine.lastLocalInputAt + AwayModeLimits.idleBeforeCover }
        let batteryEndsAt = machine.batteryEndsIn(now: now).map { _ in
            (machine.onBatterySince ?? now) + AwayModeLimits.batteryGraceWithoutPhone
        }
        return Signature(phase: machine.phase,
                         wantsCover: machine.wantsCover,
                         holdsDisplayAwake: machine.holdsDisplayAwake,
                         protocolState: machine.protocolState,
                         unavailable: unavailable,
                         lowPowerMode: lastPower.lowPowerMode,
                         coversAtStep: coversAt.map(Self.step),
                         batteryEndsAtStep: batteryEndsAt.map(Self.step))
    }

    private static func step(_ time: TimeInterval) -> Int {
        Int((time / notifyStep).rounded(.down))
    }
}
