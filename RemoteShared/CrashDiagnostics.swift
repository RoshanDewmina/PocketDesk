import Foundation
import Combine
import CoreFoundation
#if canImport(MetricKit) && (os(iOS) || os(macOS))
import MetricKit
#endif

/// Local support evidence, never a raw Apple payload. Only enums, numbers, dates and
/// binary UUIDs cross this boundary; exception messages, paths, absolute addresses,
/// signposts, state labels and environment metadata are deliberately discarded.
struct CrashDiagnosticStack: Codable, Equatable {
    static let maximumFrames = 256
    static let maximumThreads = 32
    static let maximumDepth = 64
    static let maximumInputBytes = 2 * 1024 * 1024
    struct Thread: Codable, Equatable { var threadAttributed: Bool? }
    struct Frame: Codable, Equatable {
        var thread: Int
        var parent: Int?
        var binaryUUID: UUID?
        var offsetIntoBinaryTextSegment: UInt64?
        var sampleCount: Int?
    }
    var callStackPerThread: Bool?
    var threads: [Thread]
    var frames: [Frame]
    var truncated: Bool
    static let empty = Self(callStackPerThread: nil, threads: [], frames: [], truncated: false)

    /// MXCallStackTree's documented JSON schema. A new schema fails safely with
    /// an empty/truncated stack; unrecognized strings/keys are never copied.
    static func legacyJSON(_ data: Data) -> Self {
        guard data.count <= maximumInputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else {
            var result = empty; result.truncated = true; return result
        }
        var result = Self(callStackPerThread: tree["callStackPerThread"] as? Bool, threads: [], frames: [], truncated: stacks.count > maximumThreads)
        func integer(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let exact = UInt64(number.stringValue) else { return nil }
            return exact
        }
        func visit(_ nodes: [[String: Any]], thread: Int, parent: Int?, depth: Int) {
            guard depth < maximumDepth else { if !nodes.isEmpty { result.truncated = true }; return }
            for node in nodes {
                guard result.frames.count < maximumFrames else { result.truncated = true; return }
                let index = result.frames.count
                let samples = integer(node["sampleCount"]).flatMap { Int(exactly: $0) }
                result.frames.append(.init(thread: thread, parent: parent,
                    binaryUUID: (node["binaryUUID"] as? String).flatMap(UUID.init(uuidString:)),
                    offsetIntoBinaryTextSegment: integer(node["offsetIntoBinaryTextSegment"]), sampleCount: samples))
                visit(node["subFrames"] as? [[String: Any]] ?? [], thread: thread, parent: index, depth: depth + 1)
            }
        }
        for (index, stack) in stacks.prefix(maximumThreads).enumerated() {
            result.threads.append(.init(threadAttributed: stack["threadAttributed"] as? Bool))
            visit(stack["callStackRootFrames"] as? [[String: Any]] ?? [], thread: index, parent: nil, depth: 0)
        }
        return result
    }

    func validate() throws {
        guard threads.count <= Self.maximumThreads, frames.count <= Self.maximumFrames else { throw CrashDiagnosticStore.Failure.invalidReport }
        var depths: [Int] = []
        for (index, frame) in frames.enumerated() {
            guard threads.indices.contains(frame.thread), frame.sampleCount.map({ $0 >= 0 }) ?? true else { throw CrashDiagnosticStore.Failure.invalidReport }
            var depth = 0
            if let parent = frame.parent {
                guard parent >= 0, parent < index, frames[parent].thread == frame.thread else { throw CrashDiagnosticStore.Failure.invalidReport }
                depth = depths[parent] + 1
            }
            guard depth < Self.maximumDepth else { throw CrashDiagnosticStore.Failure.invalidReport }
            depths.append(depth)
        }
    }
}

struct CrashDiagnosticEvent: Codable, Equatable {
    enum Kind: String, Codable { case crash, hang, cpuException, diskWriteException, appLaunch, memoryException }
    var kind: Kind
    var begin: Date
    var end: Date
    var stack: CrashDiagnosticStack
    var signal: Int? = nil
    var exceptionType: Int? = nil
    var durationSeconds: Double? = nil
    var cpuSeconds: Double? = nil
    var sampledSeconds: Double? = nil
    var bytesWritten: Double? = nil

    func validate() throws {
        guard begin.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= begin,
              [durationSeconds, cpuSeconds, sampledSeconds, bytesWritten].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),
              signal.map({ $0 >= 0 }) ?? true, exceptionType.map({ $0 >= 0 }) ?? true else { throw CrashDiagnosticStore.Failure.invalidReport }
        try stack.validate()
    }
}

struct CrashDiagnosticReport: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var event: CrashDiagnosticEvent
    /// Collecting app/OS identity. An Apple backlog may originate from an older
    /// build; use stack binary UUIDs to select the matching retained dSYM.
    var artifact: DiagnosticArtifact? = .current
}

/// A private, backup-excluded local directory. Reads, callbacks and explicit
/// exports are serialized; retention is enforced on startup, save and export.
final class CrashDiagnosticStore {
    static let maximumReports = 10
    static let retention: TimeInterval = 7 * 86400
    static let maximumReportBytes = 64 * 1024
    static let maximumTotalBytes = 256 * 1024
    enum Failure: Error { case invalidReport, unsafeDirectory }
    private let directory: URL
    private let now: () -> Date
    private let lock = NSRecursiveLock()

    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarsideMetricKitDiagnostics", isDirectory: true)
        self.now = now
    }
    private func safeDirectory() -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }
    func load() -> [CrashDiagnosticReport] {
        lock.lock(); defer { lock.unlock() }
        guard safeDirectory() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        let current = now()
        var records: [(CrashDiagnosticReport, Int, URL)] = []
        for file in files where file.pathExtension == "json" {
            guard let meta = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  meta.isRegularFile == true, meta.isSymbolicLink != true,
                  let size = meta.fileSize, size <= Self.maximumReportBytes,
                  let data = try? Data(contentsOf: file), data.count <= Self.maximumReportBytes,
                  let report = try? JSONDecoder().decode(CrashDiagnosticReport.self, from: data),
                  report.id.uuidString + ".json" == file.lastPathComponent,
                  report.createdAt.timeIntervalSince1970.isFinite,
                  current.timeIntervalSince(report.createdAt) >= 0, current.timeIntervalSince(report.createdAt) <= Self.retention,
                  report.artifact?.valid ?? true,
                  (try? report.event.validate()) != nil else { try? FileManager.default.removeItem(at: file); continue }
            records.append((report, data.count, file))
        }
        records.sort { $0.0.createdAt == $1.0.createdAt ? $0.0.id.uuidString < $1.0.id.uuidString : $0.0.createdAt > $1.0.createdAt }
        var bytes = 0, kept: [CrashDiagnosticReport] = []
        for (report, size, file) in records {
            guard kept.count < Self.maximumReports, bytes + size <= Self.maximumTotalBytes else { try? FileManager.default.removeItem(at: file); continue }
            bytes += size; kept.append(report)
        }
        return kept
    }
    func save(_ event: CrashDiagnosticEvent) throws {
        lock.lock(); defer { lock.unlock() }
        try event.validate()
        let report = CrashDiagnosticReport(id: UUID(), createdAt: now(), event: event)
        guard report.createdAt.timeIntervalSince1970.isFinite, report.artifact?.valid ?? true else { throw Failure.invalidReport }
        let data = try JSONEncoder().encode(report)
        guard data.count <= Self.maximumReportBytes else { throw Failure.invalidReport }
        if FileManager.default.fileExists(atPath: directory.path) {
            guard safeDirectory() else { throw Failure.unsafeDirectory }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var localDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        _ = load()
        try data.write(to: directory.appendingPathComponent(report.id.uuidString + ".json"), options: .atomic)
        _ = load()
    }
    /// Data leaves the service only through this caller-invoked export. Canonical
    /// re-encoding also discards unknown fields in preexisting local files.
    func export(id: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let report = load().first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(report)
    }
    func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard safeDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        for report in load() { delete(report.id) }
    }
}

protocol CrashDiagnosticSource: AnyObject {
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void)
    func stop()
}

final class CrashDiagnostics {
    static let defaultsKey = "PocketDeskMetricKit"
    /// Lazy and retained across scenes. Reading it does not start MetricKit.
    static let shared = CrashDiagnostics()
    let enabled: Bool
    let reportsChanged = PassthroughSubject<Void, Never>()
    private let store: CrashDiagnosticStore
    private let makeSource: () -> CrashDiagnosticSource
    private var source: CrashDiagnosticSource?
    private var generation = UUID()
    private var failed = false
    private let lock = NSRecursiveLock()
    var storageFailure: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    convenience init(defaults: UserDefaults = .standard, store: CrashDiagnosticStore = CrashDiagnosticStore(), source: @escaping () -> CrashDiagnosticSource = CrashDiagnostics.platformSource) {
        // Process-start snapshot: absent => ON, defaults write ... NO => OFF.
        self.init(enabled: defaults.object(forKey: Self.defaultsKey) == nil || defaults.bool(forKey: Self.defaultsKey), store: store, source: source)
    }
    init(enabled: Bool, store: CrashDiagnosticStore, source: @escaping () -> CrashDiagnosticSource) {
        self.enabled = enabled; self.store = store; self.makeSource = source
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard enabled, source == nil else { return }
        _ = store.load()
        let next = makeSource(); source = next; generation = UUID()
        let activeGeneration = generation
        next.start { [weak self] event in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.source != nil, self.generation == activeGeneration else { return }
            do { try self.store.save(event); self.failed = false; self.reportsChanged.send(()) } catch { self.failed = true }
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        let previous = source; source = nil; generation = UUID(); previous?.stop()
    }
    deinit { source?.stop() }
    func reports() -> [CrashDiagnosticReport] { store.load() }
    func export(id: UUID) -> Data? { store.export(id: id) }
    func delete(_ id: UUID) { store.delete(id); reportsChanged.send(()) }
    func deleteAll() { store.deleteAll(); reportsChanged.send(()) }
    static func platformSource() -> CrashDiagnosticSource {
        #if canImport(MetricKit) && (os(iOS) || os(macOS))
        if #available(iOS 27.0, macOS 27.0, *) { return ModernCrashDiagnosticSource() }
        return LegacyCrashDiagnosticSource()
        #else
        return UnavailableCrashDiagnosticSource()
        #endif
    }
}

private final class UnavailableCrashDiagnosticSource: CrashDiagnosticSource {
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) {}
    func stop() {}
}

#if canImport(MetricKit) && (os(iOS) || os(macOS))
/// The actual OS26 subscriber is injectable so tests exercise didReceive(_:) and
/// registration/removal without subscribing the test runner to Apple's manager.
final class LegacyCrashDiagnosticSource: NSObject, CrashDiagnosticSource, MXMetricManagerSubscriber {
    private let add: (MXMetricManagerSubscriber) -> Void
    private let remove: (MXMetricManagerSubscriber) -> Void
    private let lock = NSLock()
    private var receive: ((CrashDiagnosticEvent) -> Void)?
    init(add: @escaping (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.add($0) }, remove: @escaping (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.remove($0) }) {
        self.add = add; self.remove = remove
        super.init()
    }
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) {
        lock.lock(); let wasStarted = self.receive != nil; self.receive = receive; lock.unlock()
        if !wasStarted { add(self) }
    }
    func stop() {
        lock.lock(); let wasStarted = receive != nil; receive = nil; lock.unlock()
        if wasStarted { remove(self) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock(); let sink = receive; lock.unlock()
        guard let sink else { return }
        // Bound work for a backlog delivered in one callback. Retention bounds
        // local files independently; discarded reports never enter storage.
        var remaining = CrashDiagnosticStore.maximumReports
        for payload in payloads.prefix(CrashDiagnosticStore.maximumReports) {
            func emit(_ event: CrashDiagnosticEvent) { guard remaining > 0 else { return }; remaining -= 1; sink(event) }
            for diagnostic in (payload.crashDiagnostics ?? []).prefix(remaining) {
                emit(.init(kind: .crash, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                    stack: .legacyJSON(diagnostic.callStackTree.jsonRepresentation()), signal: diagnostic.signal?.intValue, exceptionType: diagnostic.exceptionType?.intValue))
            }
            for diagnostic in (payload.hangDiagnostics ?? []).prefix(remaining) {
                emit(.init(kind: .hang, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                    stack: .legacyJSON(diagnostic.callStackTree.jsonRepresentation()), durationSeconds: diagnostic.hangDuration.converted(to: .seconds).value))
            }
            for diagnostic in (payload.cpuExceptionDiagnostics ?? []).prefix(remaining) {
                emit(.init(kind: .cpuException, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                    stack: .legacyJSON(diagnostic.callStackTree.jsonRepresentation()), cpuSeconds: diagnostic.totalCPUTime.converted(to: .seconds).value,
                    sampledSeconds: diagnostic.totalSampledTime.converted(to: .seconds).value))
            }
            for diagnostic in (payload.diskWriteExceptionDiagnostics ?? []).prefix(remaining) {
                emit(.init(kind: .diskWriteException, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                    stack: .legacyJSON(diagnostic.callStackTree.jsonRepresentation()), bytesWritten: diagnostic.totalWritesCaused.converted(to: .bytes).value))
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CrashDiagnosticStack {
    static func modern(_ tree: CallStackTree) -> Self {
        var result = Self(callStackPerThread: tree.callStackPerThread, threads: [], frames: [], truncated: tree.callStackThreads.count > maximumThreads)
        func visit(_ frames: ContiguousArray<CallStackFrame>, thread: Int, parent: Int?, depth: Int) {
            guard depth < maximumDepth else { if !frames.isEmpty { result.truncated = true }; return }
            for frame in frames {
                guard result.frames.count < maximumFrames else { result.truncated = true; return }
                let index = result.frames.count
                result.frames.append(.init(thread: thread, parent: parent, binaryUUID: frame.binaryUUID,
                    offsetIntoBinaryTextSegment: frame.offsetIntoBinaryTextSegment,
                    sampleCount: frame.sampleCount.flatMap { $0 >= 0 ? $0 : nil }))
                visit(frame.subFrames, thread: thread, parent: index, depth: depth + 1)
            }
        }
        for (index, thread) in tree.callStackThreads.prefix(maximumThreads).enumerated() {
            result.threads.append(.init(threadAttributed: thread.threadAttributed))
            visit(thread.rootFrames, thread: index, parent: nil, depth: 0)
        }
        return result
    }
}

@available(iOS 27.0, macOS 27.0, *)
final class ModernCrashDiagnosticSource: CrashDiagnosticSource {
    private var task: Task<Void, Never>?
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) {
        guard task == nil else { return }
        // Manager retained by this task; one consumer and no state-reporting domains.
        task = Task.detached {
            guard !Task.isCancelled else { return }
            let manager = MetricManager()
            for await report in manager.diagnosticReports {
                guard !Task.isCancelled else { break }
                if let event = Self.event(report) { receive(event) }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
    static func event(_ report: DiagnosticReport) -> CrashDiagnosticEvent? {
        let begin = report.timeRange.start, end = report.timeRange.end
        switch report.result {
        case .crash(let diagnostic):
            return .init(kind: .crash, begin: begin, end: end, stack: .modern(diagnostic.callStackTree), signal: diagnostic.signal, exceptionType: diagnostic.exceptionType)
        case .hang(let diagnostic):
            return .init(kind: .hang, begin: begin, end: end, stack: .modern(diagnostic.callStackTree), durationSeconds: diagnostic.hangDuration.converted(to: .seconds).value)
        case .cpuException(let diagnostic):
            return .init(kind: .cpuException, begin: begin, end: end, stack: .modern(diagnostic.callStackTree), cpuSeconds: diagnostic.totalCPUTime.converted(to: .seconds).value, sampledSeconds: diagnostic.totalSampledTime.converted(to: .seconds).value)
        case .diskWriteException(let diagnostic):
            return .init(kind: .diskWriteException, begin: begin, end: end, stack: .modern(diagnostic.callStackTree), bytesWritten: diagnostic.totalBytesWritten.converted(to: .bytes).value)
        case .appLaunch(let diagnostic):
            return .init(kind: .appLaunch, begin: begin, end: end, stack: .modern(diagnostic.callStackTree), durationSeconds: diagnostic.launchDuration.converted(to: .seconds).value)
        #if os(iOS)
        case .memoryException(let diagnostic):
            return .init(kind: .memoryException, begin: begin, end: end, stack: .modern(diagnostic.callStackTree))
        #endif
        @unknown default: return nil
        }
    }
}
#endif
