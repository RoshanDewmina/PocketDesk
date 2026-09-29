import AppKit
import Darwin
import Foundation
import os

/// Farside's background helper. It lives inside the host app bundle, runs as a LaunchAgent the
/// host registers with ServiceManagement, and reopens the host after a crash or a hang. It never
/// reads screen content or pairing secrets; it only reads the host's small run record.
@MainActor
final class WatchdogSupervisor {
    static let pollInterval: TimeInterval = 1
    static let launchRetries = 3
    static let launchRetryDelay: TimeInterval = 5

    private let bundleURL: URL
    private let bundlePath: String
    private let bundleIdentifier: String
    private let files: WatchdogFiles
    private let bootSession = HostProcessInfo.bootSession()
    private let policy = WatchdogPolicy()
    private let executablePath: String
    private let executableIdentity: FileIdentity?
    private var ledger: WatchdogLedger
    private var hangKillIssuedFor: String?
    private var launchInFlight = false
    private var shuttingDown = false
    private var timer: Timer?
    private var processSource: DispatchSourceProcess?
    private var watchedPID: pid_t = 0
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "watchdog-helper")

    init?(executablePath: String) {
        guard let bundlePath = WatchdogFiles.hostBundlePath(forHelperExecutable: executablePath),
              let bundle = Bundle(path: bundlePath), let identifier = bundle.bundleIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        self.bundlePath = bundlePath
        self.bundleURL = URL(fileURLWithPath: bundlePath)
        self.bundleIdentifier = identifier
        self.executablePath = executablePath
        self.executableIdentity = FileIdentity(path: executablePath)
        files = WatchdogFiles.forHost(bundleIdentifier: identifier, bundlePath: bundlePath, applicationSupport: support)
        ledger = WatchdogStore.read(WatchdogLedger.self, from: files.ledger) ?? WatchdogLedger()
    }

    func run() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shuttingDown = true }
        })
        logger.notice("Watching \(self.bundlePath, privacy: .public)")
        tick()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // An installed update replaced this helper; launchd (KeepAlive) starts the new one.
        if let executableIdentity, let current = FileIdentity(path: executablePath), current != executableIdentity {
            logger.notice("Helper was updated; exiting so launchd starts the new version")
            exit(0)
        }
        let record = WatchdogStore.read(HostRunRecord.self, from: files.hostRecord)
        let alive = record.map { HostProcessInfo.isRunning(pid: $0.pid, executablePath: $0.executablePath) } ?? false
        if let record, alive { watch(pid: record.pid) } else { watch(pid: 0) }
        let observation = WatchdogObservation(
            record: record,
            ownedBundlePath: bundlePath,
            recordProcessAlive: alive,
            recordProcessTraced: alive && record.map { HostProcessInfo.isTraced(pid: $0.pid) } == true,
            otherInstanceRunning: otherInstanceRunning(excluding: alive ? record?.pid : nil),
            bootSession: bootSession,
            now: Date(),
            uptime: ProcessInfo.processInfo.systemUptime,
            shuttingDown: shuttingDown || launchInFlight,
            hangKillIssued: record.map { $0.launchID == hangKillIssuedFor } ?? false,
            hangNoteLaunchID: WatchdogStore.read(HostHangNote.self, from: files.hangNote)?.launchID
        )
        let before = ledger
        let decision = policy.decide(observation, ledger: &ledger)
        if ledger != before { WatchdogStore.write(ledger, to: files.ledger) }
        execute(decision, record: record)
    }

    private func execute(_ decision: WatchdogDecision, record: HostRunRecord?) {
        switch decision {
        case .idle:
            break
        case .terminateHung(let pid):
            hangKillIssuedFor = record?.launchID
            logger.error("Host heartbeat stopped; ending pid \(pid, privacy: .public) so it can be relaunched")
            kill(pid, SIGKILL)
        case .relaunch(let kind):
            logger.error("Host ended unexpectedly (\(kind.rawValue, privacy: .public)); relaunching")
            launch(arguments: [WatchdogLaunchArgument.recovered], attemptsLeft: Self.launchRetries)
        case .relaunchSafeMode(let kind):
            logger.error("Host ended unexpectedly (\(kind.rawValue, privacy: .public)) again; stopping after repeated crashes")
            launch(arguments: [WatchdogLaunchArgument.recovered, WatchdogLaunchArgument.safeMode],
                   attemptsLeft: Self.launchRetries)
        case .stopped(let kind):
            logger.error("Host ended (\(kind.rawValue, privacy: .public)) while stopped after repeated crashes; not relaunching")
        }
    }

    private func launch(arguments: [String], attemptsLeft: Int) {
        guard attemptsLeft > 0, !shuttingDown else { launchInFlight = false; return }
        launchInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.shuttingDown else { self.launchInFlight = false; return }
                if self.otherInstanceRunning(excluding: nil) { self.launchInFlight = false; return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                configuration.createsNewApplicationInstance = false
                configuration.promptsUserIfNeeded = false
                configuration.arguments = arguments
                NSWorkspace.shared.openApplication(at: self.bundleURL, configuration: configuration) { _, error in
                    let message = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard let message else { self.launchInFlight = false; return }
                        self.logger.error("Relaunch failed: \(message, privacy: .public)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchRetryDelay) { [weak self] in
                            MainActor.assumeIsolated { self?.launch(arguments: arguments, attemptsLeft: attemptsLeft - 1) }
                        }
                    }
                }
            }
        }
    }

    private func otherInstanceRunning(excluding pid: pid_t?) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { app in
            guard !app.isTerminated, app.processIdentifier != pid, let url = app.bundleURL else { return false }
            return WatchdogFiles.normalized(url.path) == bundlePath
        }
    }

    /// Reacts to the host's exit at once instead of at the next poll.
    private func watch(pid: pid_t) {
        guard pid != watchedPID else { return }
        processSource?.cancel()
        processSource = nil
        watchedPID = pid
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.processSource?.cancel()
                self.processSource = nil
                self.watchedPID = 0
                self.tick()
            }
        }
        source.resume()
        processSource = source
    }
}

struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let modified: Int

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        modified = Int(info.st_mtimespec.tv_sec)
    }
}
