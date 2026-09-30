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
                               crashLoopResetAt: previous?.crashLoopResetAt)
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

    func setAwayCoverUp(_ up: Bool) {
        guard (record.awayCoverUp ?? false) != up else { return }
        record.awayCoverUp = up
        beat()
        scheduleHeartbeat()
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
        record.awayCoverUp = false
        let snapshot = record, url = files.hostRecord
        writer.sync { _ = WatchdogStore.write(snapshot, to: url) }
    }

    var ledger: WatchdogLedger? { WatchdogStore.read(WatchdogLedger.self, from: files.ledger) }

    /// Runs on the hang watchdog's thread while the main thread is stuck: record why, then end.
    nonisolated static func hangHandler(files: WatchdogFiles, launchID: String) -> @Sendable (TimeInterval) -> Void {
        { stall in
            _ = WatchdogStore.write(HostHangNote(launchID: launchID, at: Date(), stalledSeconds: stall),
                                    to: files.hangNote)
            _exit(3)
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
