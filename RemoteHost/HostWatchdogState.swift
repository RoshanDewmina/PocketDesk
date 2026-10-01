import Foundation
import Darwin

/// State the host and its watchdog helper exchange on disk. Each file has exactly one writer:
/// the host writes `host.json` and `hang.json`; the helper writes `watchdog.json`.
struct WatchdogFiles: Equatable {
    let directory: URL

    var hostRecord: URL { directory.appendingPathComponent("host.json") }
    var ledger: URL { directory.appendingPathComponent("watchdog.json") }
    var hangNote: URL { directory.appendingPathComponent("hang.json") }

    /// Scoped to one copy of the app, so a development build never shares supervision state
    /// with the installed host even though both carry the same bundle identifier.
    static func forHost(bundleIdentifier: String, bundlePath: String, applicationSupport: URL) -> WatchdogFiles {
        let scope = String(format: "%016llx", fnv1a(normalized(bundlePath)))
        return WatchdogFiles(directory: applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Watchdog", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true))
    }

    /// `Foo.app/Contents/MacOS/tool` → `Foo.app`, or nil when the tool is not inside an app bundle.
    static func hostBundlePath(forHelperExecutable executable: String) -> String? {
        let macOS = URL(fileURLWithPath: normalized(executable)).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return normalized(bundle.path)
    }

    static func isInside(_ path: String, bundle: String) -> Bool {
        let bundle = normalized(bundle)
        return normalized(path).hasPrefix(bundle + "/")
    }

    static func normalized(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// What the running host publishes about itself. Written at launch, refreshed by a main-thread
/// heartbeat, and marked clean on an intentional quit.
struct HostRunRecord: Codable, Equatable {
    static let currentVersion = 1

    var version = HostRunRecord.currentVersion
    var pid: Int32
    var launchID: String
    var bootSession: String
    var executablePath: String
    var startedAt: Date
    var heartbeatUptime: TimeInterval
    var heartbeatAt: Date
    var cleanExit = false
    var curtainUp = false
    var safeMode = false
    /// Set when the person at the Mac resumes after a crash-loop stop.
    var crashLoopResetAt: Date?
    /// Optional so records written by older hosts still decode.
    var awayCoverUp: Bool?
}

enum WatchdogExitKind: String, Codable, Equatable {
    case crash, hang
}

/// The helper's memory of recent unexpected exits in this boot session.
struct WatchdogLedger: Codable, Equatable {
    var version = 1
    var bootSession: String?
    var unexpectedExits: [Date] = []
    var handledLaunchID: String?
    var relaunches = 0
    var lastRelaunchAt: Date?
    var lastExit: WatchdogExitKind?
    var lastExitAt: Date?
    /// Set once the crash-loop limit is reached; nothing is relaunched until the host clears it.
    var stoppedAt: Date?
    var safeModeLaunchedAt: Date?

    func isStopped(inBoot boot: String) -> Bool { bootSession == boot && stoppedAt != nil }
}

/// Written by the in-process hang watchdog just before it ends a stalled host.
struct HostHangNote: Codable, Equatable {
    var launchID: String
    var at: Date
    var stalledSeconds: Double
}

/// Three unexpected exits inside five minutes stop automatic relaunching.
enum CrashLoopGuard {
    static let limit = 3
    static let window: TimeInterval = 5 * 60
}

struct WatchdogObservation: Equatable {
    var record: HostRunRecord?
    /// The helper supervises only the copy of the app that contains it.
    var ownedBundlePath: String
    /// `record.pid` is alive and still runs `record.executablePath`.
    var recordProcessAlive: Bool
    var recordProcessTraced = false
    /// Another instance of this copy is running (for example, opened again by hand).
    var otherInstanceRunning = false
    var bootSession: String
    var now: Date
    var uptime: TimeInterval
    var shuttingDown = false
    /// The helper already sent SIGKILL to this launch for a stale heartbeat.
    var hangKillIssued = false
    var hangNoteLaunchID: String?
}

enum WatchdogDecision: Equatable {
    case idle
    case terminateHung(pid: Int32)
    case relaunch(WatchdogExitKind)
    /// The crash-loop limit was just reached: open once more with sharing paused, so the Mac
    /// shows why Farside stopped instead of vanishing.
    case relaunchSafeMode(WatchdogExitKind)
    /// Already stopped after repeated crashes; this exit is recorded but not relaunched.
    case stopped(WatchdogExitKind)
}

struct WatchdogPolicy {
    var hangTimeout: TimeInterval = 45
    var curtainHangTimeout: TimeInterval = 6
    var crashLoopLimit = CrashLoopGuard.limit
    var crashLoopWindow = CrashLoopGuard.window

    func decide(_ observation: WatchdogObservation, ledger: inout WatchdogLedger) -> WatchdogDecision {
        if ledger.bootSession != observation.bootSession {
            ledger = WatchdogLedger(bootSession: observation.bootSession)
        }
        guard !observation.shuttingDown, let record = observation.record,
              record.bootSession == observation.bootSession,
              WatchdogFiles.isInside(record.executablePath, bundle: observation.ownedBundlePath)
        else { return .idle }

        if let reset = record.crashLoopResetAt, let stopped = ledger.stoppedAt, reset > stopped {
            ledger.stoppedAt = nil
            ledger.safeModeLaunchedAt = nil
            ledger.unexpectedExits = []
        }

        if observation.recordProcessAlive {
            guard !record.cleanExit, !observation.recordProcessTraced, !observation.hangKillIssued else { return .idle }
            // This helper cannot verify Lock Screen. It must not remove an Away cover by SIGKILL.
            guard record.awayCoverUp != true else { return .idle }
            let timeout = record.curtainUp ? curtainHangTimeout : hangTimeout
            let silence = observation.uptime - record.heartbeatUptime
            return silence > timeout ? .terminateHung(pid: record.pid) : .idle
        }

        guard !observation.otherInstanceRunning, !record.cleanExit,
              ledger.handledLaunchID != record.launchID else { return .idle }
        ledger.handledLaunchID = record.launchID
        let kind: WatchdogExitKind = observation.hangKillIssued || observation.hangNoteLaunchID == record.launchID
            ? .hang : .crash
        ledger.lastExit = kind
        ledger.lastExitAt = observation.now
        if ledger.stoppedAt != nil { return .stopped(kind) }

        ledger.unexpectedExits = ledger.unexpectedExits.filter {
            $0 <= observation.now && observation.now.timeIntervalSince($0) < crashLoopWindow
        }
        ledger.unexpectedExits.append(observation.now)
        ledger.lastRelaunchAt = observation.now
        ledger.relaunches += 1
        if ledger.unexpectedExits.count >= crashLoopLimit {
            ledger.stoppedAt = observation.now
            ledger.safeModeLaunchedAt = observation.now
            return .relaunchSafeMode(kind)
        }
        return .relaunch(kind)
    }
}

/// How a freshly launched host reads the previous run and the helper's ledger.
struct HostLaunchAssessment: Equatable {
    /// The previous run of this copy ended without a clean quit in this boot session.
    var recoveredFromUnexpectedExit = false
    var previousExit: WatchdogExitKind?
    /// Start with sharing paused and explain that Farside stopped after repeated crashes.
    var safeMode = false
    /// The previous run ended unexpectedly while Away mode covered the Mac: lock before anything else.
    var lockFirst = false

    static func assess(previous: HostRunRecord?, ledger: WatchdogLedger?, hangNote: HostHangNote?,
                       bootSession: String, previousProcessAlive: Bool,
                       safeModeArgument: Bool) -> HostLaunchAssessment {
        var result = HostLaunchAssessment()
        if let previous, previous.bootSession == bootSession, !previousProcessAlive {
            result.lockFirst = previous.awayCoverUp == true
        }
        if let previous, previous.bootSession == bootSession, !previous.cleanExit, !previousProcessAlive {
            result.recoveredFromUnexpectedExit = true
            result.previousExit = hangNote?.launchID == previous.launchID ? .hang : .crash
        }
        let stopped = ledger?.isStopped(inBoot: bootSession) == true
        let resetAfterStop: Bool = {
            guard let reset = previous?.crashLoopResetAt, let stoppedAt = ledger?.stoppedAt else { return false }
            return reset > stoppedAt
        }()
        result.safeMode = safeModeArgument || (stopped && !resetAfterStop)
        return result
    }
}

enum WatchdogLaunchArgument {
    static let recovered = "--farside-recovered"
    static let safeMode = "--farside-safe-mode"
}

enum HostProcessInfo {
    /// Changes on every boot; separates this boot's crashes from records left before a restart.
    static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isRunning(pid: pid_t, executablePath: String) -> Bool {
        guard let path = Self.executablePath(of: pid) else { return false }
        return WatchdogFiles.normalized(path) == WatchdogFiles.normalized(executablePath)
    }

    static func isTraced(pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

enum WatchdogStore {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
