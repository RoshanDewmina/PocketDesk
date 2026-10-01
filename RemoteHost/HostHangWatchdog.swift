import Foundation
import os

/// Measures how long a probe posted to the main queue has waited. A late check by the watchdog
/// thread itself (timer coalescing, App Nap) never looks like a stall, because only an
/// unanswered probe counts.
struct MainThreadStallDetector: Equatable {
    private(set) var pendingSince: TimeInterval?

    var needsProbe: Bool { pendingSince == nil }

    mutating func probeSent(at now: TimeInterval) {
        if pendingSince == nil { pendingSince = now }
    }

    mutating func probeAnswered() {
        pendingSince = nil
    }

    func stall(at now: TimeInterval) -> TimeInterval {
        guard let pendingSince, now >= pendingSince else { return 0 }
        return now - pendingSince
    }

    func isStalled(at now: TimeInterval, threshold: TimeInterval) -> Bool {
        pendingSince != nil && stall(at: now) >= threshold
    }
}

enum HangWatchdogPolicy {
    static let recoveryThreshold: TimeInterval = 12
    /// A hung host must not leave the Mac's screen covered for long.
    static let curtainThreshold: TimeInterval = 4

    /// Nil means a stall is tolerated: nothing would relaunch the host, no curtain is up and the
    /// display is not on a Big Text mode that only this process's exit reverts.
    static func threshold(curtainUp: Bool, recoveryEnabled: Bool, bigTextEngaged: Bool = false, displayChanging: Bool = false) -> TimeInterval? {
        // Display configuration can synchronously block a healthy main thread. Keep a bounded
        // recovery deadline even with the curtain up; its oversized windows remain covering.
        if displayChanging { return curtainUp || recoveryEnabled || bigTextEngaged ? recoveryThreshold : nil }
        if curtainUp || bigTextEngaged { return curtainThreshold }
        return recoveryEnabled ? recoveryThreshold : nil
    }
}

/// Ends the host when its main thread stops answering, so the watchdog helper can relaunch it and
/// any privacy curtain (a window owned by this process) disappears with it.
final class HostHangWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = MainThreadStallDetector()
    private var curtainUp = false
    private var recoveryEnabled = true
    private var bigTextEngaged = false
    private var displayChanging = false
    private var started = false
    private let interval: TimeInterval
    private let onHang: @Sendable (TimeInterval) -> Bool
    private let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "watchdog")

    init(interval: TimeInterval = 0.5, onHang: @escaping @Sendable (TimeInterval) -> Void) {
        self.interval = interval
        self.onHang = { stall in onHang(stall); return true }
    }

    private init(interval: TimeInterval, terminationHandler: @escaping @Sendable (TimeInterval) -> Bool) {
        self.interval = interval
        self.onHang = terminationHandler
    }

    static func retainingUnconfirmedCover(interval: TimeInterval = 0.5,
        onHang: @escaping @Sendable (TimeInterval) -> Bool) -> HostHangWatchdog {
        HostHangWatchdog(interval: interval, terminationHandler: onHang)
    }

    static var disabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment["FARSIDE_DISABLE_HANG_WATCHDOG"] == "1"
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !Self.disabledByEnvironment else { return }
        started = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Farside hang watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func update(curtainUp: Bool, recoveryEnabled: Bool, bigTextEngaged: Bool = false, displayChanging: Bool = false) {
        lock.lock()
        self.curtainUp = curtainUp
        self.recoveryEnabled = recoveryEnabled
        self.bigTextEngaged = bigTextEngaged
        self.displayChanging = displayChanging
        lock.unlock()
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: interval)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if detector.needsProbe {
                detector.probeSent(at: now)
                lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.answer() }
                continue
            }
            let threshold = HangWatchdogPolicy.threshold(curtainUp: curtainUp, recoveryEnabled: recoveryEnabled,
                                                         bigTextEngaged: bigTextEngaged, displayChanging: displayChanging)
            let stall = detector.stall(at: now)
            let stalled = threshold.map { detector.isStalled(at: now, threshold: $0) } ?? false
            lock.unlock()
            if stalled && !HostProcessInfo.isTraced(pid: getpid()) {
                logger.fault("Main thread stalled for \(stall, privacy: .public) s; ending the host for recovery")
                if onHang(stall) { return }
                // The covered host could not prove a lock. Retain the process/cover and retry.
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func answer() {
        lock.lock()
        detector.probeAnswered()
        lock.unlock()
    }
}
