#if DEBUG
import Foundation
import CoreGraphics
import Darwin

/// Debug-only end-to-end harness support shared by the Mac host, the phone, the stub host and
/// tests. Nothing here is compiled into Release builds. A process is in E2E mode only when it was
/// launched with the `--farside-e2e` argument *and* `FARSIDE_E2E=1` in its environment; a
/// half-configured E2E launch is refused instead of falling back to normal behaviour.
/// The contract is documented in script/e2e/README.md.
enum E2E {
    static let launchArgument = "--farside-e2e"
    static let environmentFlag = "FARSIDE_E2E"
    static let directoryVariable = "FARSIDE_E2E_DIR"
    static let runVariable = "FARSIDE_E2E_RUN_ID"
    static let signalVariable = "FARSIDE_E2E_SIGNAL_URL"
    static let spaceKeysVariable = "FARSIDE_E2E_ALLOW_SPACE_KEYS"
    static let resetArgument = "--farside-e2e-reset-pairing"
    static let tokenArgument = "--farside-e2e-token"
    static let voiceArgument = "--farside-e2e-voice-transcript"
    /// The only directory an E2E process will write to. `/tmp` resolves here on macOS.
    static let root = "/private/tmp/farside-e2e"
    static let testPadBundleID = "com.roshan.PocketDesk.FarsideTestPad"
    static let tokenFileName = "pairing-token"
    static let invitationFileName = "invitation.code"
}

struct E2EConfigError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed launch request. `requested` is false for every ordinary launch.
struct E2ELaunchOptions {
    let arguments: [String]
    let environment: [String: String]

    static var current: E2ELaunchOptions {
        E2ELaunchOptions(arguments: ProcessInfo.processInfo.arguments,
                         environment: ProcessInfo.processInfo.environment)
    }

    var laneRequested: Bool { E2ELaneContract.requested(environment) }
    var requested: Bool { arguments.contains(E2E.launchArgument) || laneRequested }

    func has(_ flag: String) -> Bool { arguments.contains(flag) }

    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Validates the switches every E2E process needs. Returns nil for an ordinary launch.
    func validatedCommon(role: E2ELaneRole = .realHost) throws -> (directory: String, runID: String)? {
        guard requested else { return nil }
        guard arguments.contains(E2E.launchArgument) else {
            throw E2EConfigError("a lane manifest requires --farside-e2e")
        }
        guard environment[E2E.environmentFlag] == "1" else {
            throw E2EConfigError("--farside-e2e requires FARSIDE_E2E=1 in the environment")
        }
        if laneRequested {
            let lane = try E2ELaneContract.validate(environment: environment, role: role)
            return (lane.root, lane.runID)
        }
        guard let raw = environment[E2E.directoryVariable], raw.hasPrefix("/") else {
            throw E2EConfigError("FARSIDE_E2E_DIR must be an absolute path")
        }
        let resolved = E2EFiles.resolved(raw)
        guard resolved == E2E.root else {
            throw E2EConfigError("FARSIDE_E2E_DIR must be \(E2E.root) (got \(resolved))")
        }
        let runID = environment[E2E.runVariable] ?? "unspecified"
        guard E2EFiles.isIdentifier(runID) else {
            throw E2EConfigError("FARSIDE_E2E_RUN_ID must be 1-64 letters, digits, '-' or '_'")
        }
        return (resolved, runID)
    }

    /// Loopback-only signaling URL; an E2E process can never pair across the network.
    func validatedSignalURL() throws -> String {
        guard let value = environment[E2E.signalVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              PairInvitation.validServer(value), let url = URL(string: value), url.scheme == "ws",
              let host = url.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        else { throw E2EConfigError("FARSIDE_E2E_SIGNAL_URL must be a loopback ws://127.0.0.1:<port>/signal URL") }
        return value
    }
}

/// Owner/permission checked file access for the harness directory.
enum E2EFiles {
    static func resolved(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func isToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    /// A private directory: real directory (not a symlink), owned by this user, no group/other write.
    static func validatePrivateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw E2EConfigError("\(path) does not exist") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw E2EConfigError("\(path) must be a directory, not a link or file") }
        guard info.st_uid == getuid() else { throw E2EConfigError("\(path) must be owned by the current user") }
        guard (info.st_mode & 0o022) == 0 else { throw E2EConfigError("\(path) must not be group or world writable") }
    }

    /// Reads a secret written by the harness: regular file, owner-only (0600), small.
    static func readSecret(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw E2EConfigError("\(path) is missing") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw E2EConfigError("\(path) must be a regular file") }
        guard info.st_uid == getuid() else { throw E2EConfigError("\(path) must be owned by the current user") }
        guard (info.st_mode & 0o777) == 0o600 else { throw E2EConfigError("\(path) must have mode 0600") }
        guard info.st_size <= 4096,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { throw E2EConfigError("\(path) is unreadable") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates `path` (0700) if needed, then validates it.
    static func ensurePrivateDirectory(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try validatePrivateDirectory(path)
    }

    /// Atomic owner-only write (temp file in the same directory, then rename).
    static func writePrivate(_ data: Data, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString).appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw E2EConfigError("could not write \(temporary)")
        }
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw E2EConfigError("could not replace \(path)")
        }
    }
}

/// JSON helpers that never throw on odd values (NaN/inf become null).
enum E2EJSON {
    static func sanitize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return NSNull() }
            return sanitize(wrapped)
        }
        switch value {
        case let double as Double: return double.isFinite ? double : NSNull()
        case let float as CGFloat: return float.isFinite ? Double(float) : NSNull()
        case let point as CGPoint: return ["x": sanitize(point.x), "y": sanitize(point.y)]
        case let size as CGSize: return ["width": sanitize(size.width), "height": sanitize(size.height)]
        case let rect as CGRect:
            return ["x": sanitize(rect.minX), "y": sanitize(rect.minY),
                    "width": sanitize(rect.width), "height": sanitize(rect.height)]
        case let dictionary as [String: Any]: return dictionary.mapValues { sanitize($0) }
        case let dictionary as [String: Any?]: return dictionary.mapValues { sanitize($0) }
        case let array as [Any]: return array.map { sanitize($0) }
        case let bool as Bool: return bool
        case let int as Int: return int
        case let int as UInt64: return int
        case let int as Int64: return int
        case let int as UInt32: return int
        case let int as Int32: return int
        case let string as String: return string
        case let number as NSNumber: return number
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }

    static func data(_ object: [String: Any]) -> Data? {
        let clean = sanitize(object)
        guard JSONSerialization.isValidJSONObject(clean) else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Converts a Codable value (for example a stats report) into a JSON dictionary.
    static func dictionary<T: Encodable>(_ value: T?) -> [String: Any]? {
        guard let value, let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

/// Serialized writer for one E2E output directory: append-only events and an atomic state file.
final class E2ERecorder: @unchecked Sendable {
    let directory: String
    let role: String
    let runID: String
    private let queue: DispatchQueue
    private var eventsHandle: FileHandle?
    private var sequence: UInt64 = 0

    init(directory: String, role: String, runID: String) throws {
        try E2EFiles.ensurePrivateDirectory(directory)
        self.directory = directory
        self.role = role
        self.runID = runID
        queue = DispatchQueue(label: "farside.e2e.\(role)")
        let path = (directory as NSString).appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        eventsHandle = FileHandle(forWritingAtPath: path)
        _ = try? eventsHandle?.seekToEnd()
    }

    deinit { try? eventsHandle?.close() }

    func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    /// Appends one JSON line to `events.jsonl` (or another log in the same directory).
    func event(_ type: String, _ fields: [String: Any] = [:], log: String = "events.jsonl") {
        let now = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            sequence &+= 1
            var line = fields
            line["type"] = type
            line["t"] = now
            line["mono"] = uptime
            line["seq"] = sequence
            line["role"] = role
            line["run"] = runID
            line["pid"] = Int(getpid())
            guard var data = E2EJSON.data(line) else { return }
            data.append(0x0A)
            if log == "events.jsonl" {
                try? eventsHandle?.write(contentsOf: data)
            } else {
                appendLine(data, to: path(log))
            }
        }
    }

    /// Atomically replaces `name` (default `state.json`) with the given object.
    func writeState(_ object: [String: Any], name: String = "state.json") {
        var state = object
        state["t"] = Date().timeIntervalSince1970
        state["mono"] = ProcessInfo.processInfo.systemUptime
        state["role"] = role
        state["run"] = runID
        state["pid"] = Int(getpid())
        queue.async { [self] in
            guard let data = E2EJSON.data(state) else { return }
            try? E2EFiles.writePrivate(data, to: path(name))
        }
    }

    func flush() { queue.sync {} }

    private func appendLine(_ data: Data, to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Process footprint and CPU time for soak leak/regression checks.
enum E2EProcessMetrics {
    struct Sample {
        var footprintBytes: UInt64
        var residentBytes: UInt64
        var cpuSeconds: Double
    }

    static func sample() -> Sample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return Sample(footprintBytes: result == KERN_SUCCESS ? info.phys_footprint : 0,
                      residentBytes: result == KERN_SUCCESS ? info.resident_size : 0,
                      cpuSeconds: cpu)
    }
}

/// Tracks CPU percentage between samples.
struct E2ECPUMeter {
    private var last: (uptime: TimeInterval, cpu: Double)?

    mutating func percent(now: TimeInterval, cpuSeconds: Double) -> Double? {
        defer { last = (now, cpuSeconds) }
        guard let last, now > last.uptime else { return nil }
        return max(0, (cpuSeconds - last.cpu) / (now - last.uptime) * 100)
    }
}

/// The harness's one-time pairing token. The host consumes it on first successful use.
enum E2EPairingToken {
    enum Verdict: Equatable {
        case accepted
        case rejected(String)
    }

    /// Verifies a phone's proof body against the harness token file and deletes the file on
    /// success so the token can never approve a second phone.
    static func consume(proof body: Data?, secretsDirectory: String) -> Verdict {
        guard let body, let presented = String(data: body, encoding: .utf8), E2EFiles.isToken(presented) else {
            return .rejected("proof carries no E2E token")
        }
        do {
            try E2EFiles.validatePrivateDirectory(secretsDirectory)
            let path = (secretsDirectory as NSString).appendingPathComponent(E2E.tokenFileName)
            let expected = try E2EFiles.readSecret(path)
            guard E2EFiles.isToken(expected) else { return .rejected("token file is malformed") }
            guard E2EFiles.constantTimeEquals(expected, presented) else { return .rejected("token mismatch") }
            guard unlink(path) == 0 else { return .rejected("token could not be consumed") }
            return .accepted
        } catch {
            return .rejected(String(describing: error))
        }
    }
}

/// Reads the Test Pad's published geometry (global CoreGraphics points, top-left origin).
final class E2ETestPadGeometry {
    struct Snapshot {
        var window: CGRect?
        var elements: [String: CGRect]
        var pid: Int32?
        var fullscreen: Bool
    }

    private let path: String
    private var cached: Snapshot?
    private var cachedModification: Date?

    init(path: String = E2E.root + "/testpad-state.json") { self.path = path }

    func snapshot() -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached, cachedModification == modified { return cached }
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cached }
        func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Any],
                  let x = value["x"] as? Double, let y = value["y"] as? Double,
                  let width = value["width"] as? Double, let height = value["height"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        var elements: [String: CGRect] = [:]
        for (key, value) in (object["elements"] as? [String: Any]) ?? [:] {
            if let frame = rect(value) { elements[key] = frame }
        }
        let snapshot = Snapshot(window: rect(object["contentFrame"]) ?? rect(object["windowFrame"]),
                                elements: elements,
                                pid: (object["pid"] as? Int).map(Int32.init),
                                fullscreen: object["fullscreen"] as? Bool ?? false)
        cached = snapshot
        cachedModification = modified
        return snapshot
    }

    /// Smallest element containing a global point (targets sit inside larger areas).
    func element(at point: CGPoint) -> String? {
        guard let snapshot = snapshot() else { return nil }
        return snapshot.elements.filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
    }
}
#endif
