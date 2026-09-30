#if DEBUG
import Foundation
#if os(macOS)
import Darwin
#endif

enum PortraitABIEncoding {
    static func accepts(actualReturn: String, actualArguments: [String], expectedReturn: String, expectedArguments: [String]) -> Bool {
        actualReturn == expectedReturn && actualArguments == expectedArguments
    }
}

enum PortraitCreationPreflight {
    static func acquire<Lease, Resource>(permission: () -> Bool, audit: () throws -> Void,
                                        lease: () throws -> Lease, existingIdentity: () -> Bool,
                                        create: () throws -> Resource) throws -> (Lease, Resource) {
        guard permission() else { throw PortraitPrototypeFailure.rejected("screen-recording-denied; no permission prompt requested") }
        try audit()
        let ownedLease = try lease()
        guard !existingIdentity() else { throw PortraitPrototypeFailure.rejected("an experiment identity is already online; refusing to adopt it") }
        return (ownedLease, try create())
    }
}

/// Retain each acquired object BEFORE a later fallible stage. The controller keeps this owner until
/// capture stops and display disappearance is verified; configuration failure cannot drop its lease.
@MainActor
final class PortraitDisplayCreationOwner<Lease, Display> {
    private(set) var lease: Lease?
    private(set) var display: Display?
    private(set) var displayID: UInt32 = 0
    private(set) var hadDisplay = false
    func create(lease: Lease, construct: () throws -> Display, identify: (Display) throws -> UInt32,
                configure: (Display) throws -> Void) throws {
        guard self.lease == nil && !hadDisplay else { throw PortraitPrototypeFailure.rejected("display owner is already occupied") }
        self.lease = lease
        let acquired = try construct(); display = acquired; hadDisplay = true
        displayID = try identify(acquired)
        guard displayID != 0 else { throw PortraitPrototypeFailure.rejected("acquired display has unknown identity; cleanup cannot be certified") }
        try configure(acquired)
    }
    func releaseDisplay() { display = nil }
    func acknowledgeRemoval() { lease = nil }
}

#if os(macOS)
/// Never unlink the lock inode: a second process must acquire the same kernel advisory lock.
final class PortraitRuntimeLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(path: String = "/private/tmp/farside-portrait-\(getuid()).lock") throws -> PortraitRuntimeLease {
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PortraitPrototypeFailure.rejected("runtime lease cannot open owned no-follow file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
            Darwin.close(fd); throw PortraitPrototypeFailure.rejected("runtime lease file is not a private owned regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw PortraitPrototypeFailure.rejected("another portrait process owns the runtime lease")
        }
        return PortraitRuntimeLease(fd)
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
#endif

enum PortraitPrototypeFailure: Error, CustomStringConvertible {
    case rejected(String)
    var description: String { if case .rejected(let text) = self { return text }; return "rejected" }
}

struct PortraitPrototypeOptions {
    static let argument = "--virtual-display-portrait"
    enum Mode: String { case one = "1x", two = "2x"; var scale: Int { self == .one ? 1 : 2 } }
    enum Action: String { case interactive, smoke, check }
    let mode: Mode
    let action: Action
    let movingSeconds: Double
    let idleSeconds: Double
    static func requested(_ args: [String]) -> Bool { args.contains { $0.hasPrefix(argument) || $0.hasPrefix("--portrait-") } }
    static func parse(_ args: [String]) throws -> Self {
        guard args.filter({ $0 == argument }).count == 1,
              !args.contains(where: { $0.hasPrefix("--virtual-display-spike") }) else {
            throw PortraitPrototypeFailure.rejected("portrait launch flag required exactly once; spike conflict rejected")
        }
        var values: [String: String] = [:]
        let flags = ["--portrait-mode", "--portrait-action", "--portrait-moving-seconds", "--portrait-idle-seconds"]
        var index = 1
        while index < args.count {
            let flag = args[index]
            if flag == argument { index += 1; continue }
            guard flags.contains(flag), values[flag] == nil, index + 1 < args.count else {
                throw PortraitPrototypeFailure.rejected("unknown, duplicate or missing portrait option")
            }
            values[flag] = args[index + 1]; index += 2
        }
        guard let mode = Mode(rawValue: values["--portrait-mode"] ?? "1x"),
              let action = Action(rawValue: values["--portrait-action"] ?? "interactive"),
              let moving = Double(values["--portrait-moving-seconds"] ?? "5"), moving.isFinite, (1...10).contains(moving),
              let idle = Double(values["--portrait-idle-seconds"] ?? "2"), idle.isFinite, (1...5).contains(idle) else {
            throw PortraitPrototypeFailure.rejected("invalid portrait mode/action/duration (motion 1...10 s; idle 1...5 s)")
        }
        guard action == .smoke || (values["--portrait-moving-seconds"] == nil && values["--portrait-idle-seconds"] == nil) else {
            throw PortraitPrototypeFailure.rejected("durations require smoke action")
        }
        return Self(mode: mode, action: action, movingSeconds: moving, idleSeconds: idle)
    }
    var pixelWidth: Int { 430 * mode.scale }
    var pixelHeight: Int { 932 * mode.scale }
    func accepts(logicalWidth: Double, logicalHeight: Double, pixelsWide: Int, pixelsHigh: Int,
                 backingScale: Double, refresh: Double) -> Bool {
        logicalWidth == 430 && logicalHeight == 932 && pixelsWide == pixelWidth && pixelsHigh == pixelHeight
            && abs(backingScale - Double(mode.scale)) < 0.01 && refresh.isFinite && abs(refresh - 60) < 0.5
    }
}

/// Production capture callback owner, injectable without ScreenCaptureKit or WindowServer.
/// An outstanding start owns its resource until it completes. Stop never releases that resource
/// ahead of a late successful start; that exact resource is then stopped through the injected closure.
@MainActor
final class PortraitCaptureOwner {
    typealias Completion = (String?) -> Void
    typealias Operation = (@escaping Completion) -> Void
    enum State: String { case new, starting, running, stopping, unresolved, stopped }
    private(set) var state: State = .new
    private(set) var failure: String?
    private(set) var startPending = false
    private(set) var stopPending = false
    private(set) var cancelled = false
    private var stopAttempted = false
    private let startOperation: Operation
    private let stopOperation: Operation
    private let releaseOperation: () -> Void
    var onChange: (() -> Void)?

    init(start: @escaping Operation, stop: @escaping Operation, release: @escaping () -> Void) {
        startOperation = start; stopOperation = stop; releaseOperation = release
    }
    func start() {
        guard state == .new else { return }
        state = .starting; startPending = true
        startOperation { [self] error in finishStart(error) }
        onChange?()
    }
    func stop() {
        guard state != .stopped else { return }
        cancelled = true
        if state == .new { finishRelease(); return }
        if !startPending && !stopAttempted { issueStop() }
        onChange?()
    }
    func deadline(_ reason: String) {
        guard state != .stopped else { return }
        failure = failure ?? reason; cancelled = true; state = .unresolved
        if !startPending && !stopAttempted { issueStop() }
        onChange?()
    }
    private func finishStart(_ error: String?) {
        guard startPending else { return } // reject duplicate completion
        startPending = false
        if let error { failure = failure ?? error; cancelled = true; finishRelease(); return }
        if cancelled { issueStop() } else { state = .running; onChange?() }
    }
    private func issueStop() {
        guard !stopAttempted else { return }
        stopAttempted = true; stopPending = true; state = .stopping
        stopOperation { [self] error in
            guard stopPending else { return }
            stopPending = false
            if let error { failure = failure ?? error; state = .unresolved; onChange?() }
            else { finishRelease() }
        }
    }
    private func finishRelease() {
        state = .stopped; releaseOperation(); onChange?()
    }
}

struct PortraitRunAdmission {
    private(set) var generation: UInt64 = 0
    private(set) var occupied = false
    mutating func start() -> UInt64? {
        guard !occupied else { return nil }
        generation &+= 1; occupied = true; return generation
    }
    mutating func cancel() { generation &+= 1 }
    func accepts(_ token: UInt64) -> Bool { occupied && token == generation }
    mutating func cleaned() { occupied = false }
}

/// Bound all storage even if an unexpected high-rate callback or interactive run continues for hours.
struct PortraitFrameMetrics {
    static let capacity = 2048
    private(set) var statuses: [String: Int] = [:]
    private(set) var missing = 0
    private(set) var repeated = 0
    private(set) var nonMonotonic = 0
    private(set) var dropped = 0
    private(set) var distinct = 0
    private(set) var timesMs: [Double] = []
    private var last: Double?
    mutating func record(status: String, timeMs: Double?) {
        // Callers translate framework statuses into this fixed vocabulary.
        let safeStatus = ["complete", "idle", "blank", "suspended", "started", "stopped"].contains(status) ? status : "unknown"
        statuses[safeStatus, default: 0] += 1
        guard safeStatus == "complete" else { return }
        guard let timeMs, timeMs.isFinite, timeMs > 0 else { missing += 1; return }
        if let last, timeMs == last { repeated += 1; return }
        if let last, timeMs < last { nonMonotonic += 1; return }
        last = timeMs; distinct += 1
        if timesMs.count < Self.capacity { timesMs.append(timeMs) } else { dropped += 1 }
    }
    func report(seconds: Double) -> [String: Any] {
        let gaps = zip(timesMs.dropFirst(), timesMs).map { $0 - $1 }.sorted()
        func percentile(_ p: Double) -> Any {
            guard !gaps.isEmpty else { return NSNull() }
            return gaps[max(0, min(gaps.count - 1, Int(ceil(Double(gaps.count) * p)) - 1))]
        }
        return ["statuses": statuses, "distinctComplete": distinct, "repeated": repeated, "missing": missing,
                "nonMonotonic": nonMonotonic, "storageOverflow": dropped,
                "fps": seconds.isFinite && seconds > 0 ? Double(distinct) / seconds : 0,
                "medianGapMs": percentile(0.5), "p90GapMs": percentile(0.9), "maxGapMs": gaps.last as Any? ?? NSNull()]
    }
}
#endif
