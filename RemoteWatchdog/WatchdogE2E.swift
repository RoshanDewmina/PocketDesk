#if DEBUG
import AppKit
import Darwin

/// E2E harness only (script/e2e/README.md). With `--farside-e2e` and `FARSIDE_E2E=1` the harness
/// runs this helper directly (not through launchd) against an E2E host instance: it watches the
/// harness copy of the run record under /private/tmp/farside-e2e/host/watchdog, counts only E2E
/// host instances as running (never the owner's normal host), and relaunches the host with the same
/// E2E launch contract. The owner's registered helper and its crash-loop ledger are never touched.
enum WatchdogE2E {
    struct Configuration {
        let files: WatchdogFiles
        let environment: [String: String]
    }

    static let root = "/private/tmp/farside-e2e"
    static let passThrough = ["FARSIDE_E2E", "FARSIDE_E2E_DIR", "FARSIDE_E2E_RUN_ID",
                              "FARSIDE_E2E_SIGNAL_URL", "FARSIDE_E2E_ALLOW_SPACE_KEYS"]

    static let configuration: Configuration? = {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("--farside-e2e") else { return nil }
        let resolved = info.environment["FARSIDE_E2E_DIR"].flatMap { path -> String? in
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        guard info.environment["FARSIDE_E2E"] == "1", resolved == root else {
            FileHandle.standardError.write(Data("FarsideWatchdog: E2E mode needs FARSIDE_E2E=1 and FARSIDE_E2E_DIR=\(root)\n".utf8))
            exit(78)
        }
        var environment: [String: String] = [:]
        for key in passThrough { if let value = info.environment[key] { environment[key] = value } }
        return Configuration(files: WatchdogFiles(directory: URL(fileURLWithPath: root + "/host/watchdog", isDirectory: true)),
                             environment: environment)
    }()

    /// The relaunched host publishes this launch id, so the harness can recognise and adopt it.
    static func launchEnvironment() -> [String: String] {
        var environment = configuration?.environment ?? [:]
        environment["FARSIDE_E2E_LAUNCH_ID"] = "W\(Int(Date().timeIntervalSince1970))"
        return environment
    }

    static func isE2EInstance(pid: pid_t) -> Bool { arguments(of: pid).contains("--farside-e2e") }

    /// argv of another process of this user (KERN_PROCARGS2), empty when unavailable.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
#endif
