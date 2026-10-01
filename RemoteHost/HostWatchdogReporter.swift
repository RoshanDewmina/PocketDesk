import Foundation

/// Publishes this host run to its watchdog helper: a record at launch, a main-thread heartbeat,
/// and a clean-exit mark on an intentional quit. Also reads how the previous run ended.
@MainActor
final class HostWatchdogReporter {
    static let heartbeatInterval: TimeInterval = 10
    /// While the curtain is up the helper watches closely, so a frozen host cannot leave it up.
    static let curtainHeartbeatInterval: TimeInterval = 1

    let files: WatchdogFiles
    let assessment: HostLaunchAssessment
    let launchedAt = Date()
    private(set) var record: HostRunRecord
    private var timer: Timer?
    private let writer = DispatchQueue(label: "Farside.watchdog-record", qos: .utility)
    private let uptime: () -> TimeInterval

    init(files: WatchdogFiles, executablePath: String, bootSession: String = HostProcessInfo.bootSession(),
         pid: Int32 = getpid(), arguments: [String] = ProcessInfo.processInfo.arguments,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.files = files
        self.uptime = uptime
        let previous = WatchdogStore.read(HostRunRecord.self, from: files.hostRecord)
        let previousAlive = previous.map {
            $0.pid != pid && HostProcessInfo.isRunning(pid: $0.pid, executablePath: $0.executablePath)
        } ?? false
        assessment = HostLaunchAssessment.assess(
            previous: previous,
            ledger: WatchdogStore.read(WatchdogLedger.self, from: files.ledger),
            hangNote: WatchdogStore.read(HostHangNote.self, from: files.hangNote),
            bootSession: bootSession,
            previousProcessAlive: previousAlive,
            safeModeArgument: arguments.contains(WatchdogLaunchArgument.safeMode)
        )
        let now = Date()
        record = HostRunRecord(pid: pid, launchID: UUID().uuidString, bootSession: bootSession,
                               executablePath: executablePath, startedAt: now,
                               heartbeatUptime: uptime(), heartbeatAt: now,
                               safeMode: assessment.safeMode,
                               crashLoopResetAt: previous?.crashLoopResetAt, awayCoverUp: assessment.lockFirst ? true : nil)
    }

    static func live(bundle: Bundle = .main) -> HostWatchdogReporter? {
        guard let identifier = bundle.bundleIdentifier, let executable = bundle.executablePath,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let files = WatchdogFiles.forHost(bundleIdentifier: identifier, bundlePath: bundle.bundlePath,
                                          applicationSupport: support)
        return HostWatchdogReporter(files: files, executablePath: executable)
    }

    func start() {
        persist()
        scheduleHeartbeat()
    }

    func setCurtainUp(_ up: Bool) {
        guard record.curtainUp != up else { return }
        record.curtainUp = up
        beat()
        scheduleHeartbeat()
    }

    /// A new cover must not appear unless the exact current-run marker is atomically durable.
    @discardableResult
    func setAwayCoverUp(_ up: Bool) -> Bool {
        var snapshot = record
        snapshot.awayCoverUp = up
        snapshot.heartbeatUptime = uptime()
        snapshot.heartbeatAt = Date()
        let url = files.hostRecord
        guard writer.sync(execute: { WatchdogStore.write(snapshot, to: url) }) else { return false }
        record = snapshot
        scheduleHeartbeat()
        return true
    }

    var currentHeartbeatInterval: TimeInterval {
        record.curtainUp || record.awayCoverUp == true ? Self.curtainHeartbeatInterval : Self.heartbeatInterval
    }

    /// The person resumed sharing after a crash-loop stop; the helper supervises normally again.
    func requestCrashLoopReset() {
        record.crashLoopResetAt = Date()
        record.safeMode = false
        persist()
    }

    /// Called on an intentional quit, so the helper does not relaunch Farside.
    func markCleanExit() {
        timer?.invalidate()
        timer = nil
        record.cleanExit = true
        record.curtainUp = false
        record.awayCoverUp = record.awayCoverUp == true
        let snapshot = record, url = files.hostRecord
        writer.sync { _ = WatchdogStore.write(snapshot, to: url) }
    }

    var ledger: WatchdogLedger? { WatchdogStore.read(WatchdogLedger.self, from: files.ledger) }

    /// Covered runs retain their windows if a bounded lock request cannot be confirmed.
    /// Public lock notifications are hints; the injected verifier must supply positive proof.
    nonisolated static func hangHandler(files: WatchdogFiles, launchID: String,
                                       bootSession: String = HostProcessInfo.bootSession(),
                                       requestLock: @escaping @Sendable () -> Bool = { HostLockShortcut.post() },
                                       isLocked: @escaping @Sendable () -> Bool = { HostScreenLock.isLocked() },
                                       wait: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                       terminate: @escaping @Sendable () -> Void = { _exit(3) }) -> @Sendable (TimeInterval) -> Bool {
        { stall in
            guard let record = WatchdogStore.read(HostRunRecord.self, from: files.hostRecord),
                  record.launchID == launchID, record.bootSession == bootSession else { return false }
            if record.awayCoverUp == true {
                _ = requestLock()
                // Twenty bounded checks; neither client clocks nor an unbounded waiter control exit.
                var confirmed = isLocked()
                for _ in 0..<20 where !confirmed { wait(0.1); confirmed = isLocked() }
                guard confirmed else { return false }
            }
            guard let current = WatchdogStore.read(HostRunRecord.self, from: files.hostRecord),
                  current.launchID == launchID, current.bootSession == bootSession else { return false }
            _ = WatchdogStore.write(HostHangNote(launchID: launchID, at: Date(), stalledSeconds: stall), to: files.hangNote)
            terminate()
            return true
        }
    }

    private func scheduleHeartbeat() {
        timer?.invalidate()
        let interval = currentHeartbeatInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sampled on the main thread, so a stuck main thread stops the heartbeat.
    private func beat() {
        record.heartbeatUptime = uptime()
        record.heartbeatAt = Date()
        persist()
    }

    private func persist() {
        let snapshot = record, url = files.hostRecord
        writer.async { _ = WatchdogStore.write(snapshot, to: url) }
    }
}
