import Foundation

/// Fixed vocabulary prevents addresses, keys, titles or typed content entering retained reports.
struct DiagnosticFact: Codable, Equatable {
    enum Source: String, Codable { case observed, inferred, unknown }
    enum Metric: String, Codable, CaseIterable {
        case authenticatedEchoes, unansweredEchoes, applicationRoundTripMs, captureHealthy, controlAvailable,
             geometryAvailable, hostScreenRecording, hostPostEvents, hostAccessibility, routeDirect, routeRelay, videoKbps, videoGBPerHour, transportSentBytes, transportReceivedBytes,
             transportGBPerHour, transportIntervalsComplete, phoneThermal, phoneLowPower, hostThermal, hostLowPower, missedFramePercent,
             networkRoundTripMs, roundTripSpreadMs, hostPacerMeanMs, decodeMeanMs, hostEncodeMeanMs,
             inputPostingP95Ms, preEncodeWaitP95Ms, wifiBurstPossible, awdlCause, billableBytes,
             oneOffFileBytes, guestBytes, energyJoules, physicalGlassMs
        var title: String {
            switch self {
            case .authenticatedEchoes: "Authenticated replies"
            case .unansweredEchoes: "Unanswered probes"
            case .applicationRoundTripMs: "App round trip (includes queueing) ms"
            case .captureHealthy: "Current capture healthy"
            case .controlAvailable: "Current control available (no events posted by test)"
            case .geometryAvailable: "Current picture geometry available"
            case .hostScreenRecording: "Mac public screen-recording preflight"
            case .hostPostEvents: "Mac public event-posting preflight"
            case .hostAccessibility: "Mac cached Accessibility snapshot"
            case .routeDirect: "Selected direct media route"
            case .routeRelay: "Selected relay media route"
            case .videoKbps: "Video RTP only kbps"
            case .videoGBPerHour: "Video RTP only GB/hour estimate"
            case .transportSentBytes: "Observed intervals of peer transport payload sent bytes"
            case .transportReceivedBytes: "Observed intervals of peer transport payload received bytes"
            case .transportGBPerHour: "Recent peer transport GB/hour estimate"
            case .transportIntervalsComplete: "Continuous sampled intervals (excludes first/last unsampled bytes)"
            case .phoneThermal: "Phone public thermal state (0–3)"
            case .phoneLowPower: "Phone Low Power Mode"
            case .hostThermal: "Mac public thermal state (0–3)"
            case .hostLowPower: "Mac Low Power Mode"
            case .missedFramePercent: "Encoded frames not arriving, measured window %"
            case .networkRoundTripMs: "Selected-pair network RTT ms"
            case .roundTripSpreadMs: "Fresh RTT standard deviation ms"
            case .hostPacerMeanMs: "Mean packet send delay ms (not total sender queue)"
            case .decodeMeanMs: "Mean decode ms"
            case .hostEncodeMeanMs: "Mean encode ms"
            case .inputPostingP95Ms: "Host input posting p95 ms"
            case .preEncodeWaitP95Ms: "Pre-encode waiting p95 ms"
            case .wifiBurstPossible: "Wi-Fi burst interference may contribute"
            case .awdlCause: "AWDL causation"
            case .billableBytes: "Carrier/provider billable bytes"
            case .oneOffFileBytes: "One-off file total (not separately counted)"
            case .guestBytes: "Other guest peer total (not counted by this peer)"
            case .energyJoules: "Measured energy joules"
            case .physicalGlassMs: "Calibrated physical glass-to-glass ms"
            }
        }
    }
    let metric: Metric
    let source: Source
    let value: Double?
    init(_ metric: Metric, _ value: Double?, source: Source = .observed) {
        self.metric = metric
        self.value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.source = self.value == nil ? .unknown : source
    }
    var line: String { "\(metric.title): \(value.map { String(format: "%.2f", $0) } ?? "unknown") [\(source.rawValue)]" }
}

struct DiagnosticArtifact: Codable, Equatable {
    enum Platform: String, Codable { case mac, phone }
    let platform: Platform
    let version: String?
    let build: String?
    let os: [Int]
    static func numeric(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= 32, text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        return text
    }
    static var current: DiagnosticArtifact {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let platform = Platform.phone
        #else
        let platform = Platform.mac
        #endif
        return .init(platform: platform, version: numeric(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
            build: numeric(Bundle.main.infoDictionary?["CFBundleVersion"] as? String), os: [os.majorVersion, os.minorVersion, os.patchVersion])
    }
    var valid: Bool { (version.map { Self.numeric($0) == $0 } ?? true) && (build.map { Self.numeric($0) == $0 } ?? true) && os.count == 3 && os.allSatisfy { (0...1000).contains($0) } }
    var line: String { "Artifact \(platform.rawValue) · version \(version ?? "unknown") build \(build ?? "unknown") · OS \(os.map(String.init).joined(separator: "."))" }
}

struct SessionDiagnosticReport: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case lightPreflight, fullPreflight, session }
    enum Outcome: String, Codable { case completed, cancelled, timedOut, sessionEnded }
    let version: Int
    let id: UUID
    let createdAt: Date
    let kind: Kind
    let outcome: Outcome
    let seconds: Double
    let samples: Int
    let facts: [DiagnosticFact]
    let artifact: DiagnosticArtifact?
    init(kind: Kind, outcome: Outcome, seconds: Double, samples: Int, facts: [DiagnosticFact], at: Date = Date()) {
        version = 1; id = UUID(); artifact = .current; createdAt = at; self.kind = kind; self.outcome = outcome
        self.seconds = seconds.isFinite ? min(86400, max(0, seconds)) : 0
        self.samples = min(1000000, max(0, samples)); self.facts = Array(facts.prefix(40))
    }
    var preview: String {
        (["Farside local diagnostics · \(kind.rawValue) · \(outcome.rawValue)",
          artifact?.line ?? "Artifact unknown",
          "Report window \(Int(seconds))s · \(samples) samples. No screen, text, host name, address or pairing identifiers.",
          "Observed facts describe this artifact/session; inferred causes are suggestions. Unknown does not mean zero.",
          "Transport payload is not carrier billing or IP/wire overhead. Video RTP excludes other streams. GB is decimal.",
          "Preflight measures bounded authenticated app echoes and current health, not throughput or physical latency."] + facts.map(\.line)).joined(separator: "\n")
    }
    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite, seconds.isFinite, (0...86400).contains(seconds),
              (0...1000000).contains(samples), facts.count <= 40, artifact?.valid ?? true,
              Set(facts.map(\.metric)).count == facts.count,
              facts.allSatisfy({ $0.value.map { $0.isFinite && $0 >= 0 } ?? ($0.source == .unknown) }) else { throw RemoteError.invalidMessage }
    }
}

/// Atomic bounded local retention. Reports are opt-in exports, never uploaded automatically.
final class SessionDiagnosticStore {
    static let maximumReports = 10
    static let retention: TimeInterval = 7 * 86400
    private let directory: URL
    private let now: () -> Date
    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FarsideLocalDiagnostics", isDirectory: true)
        self.now = now
    }
    func load() -> [SessionDiagnosticReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        var reports: [SessionDiagnosticReport] = []
        for file in files where file.pathExtension == "json" {
            guard let meta = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  meta.isRegularFile == true, meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 65536,
                  let data = try? Data(contentsOf: file), let report = try? JSONDecoder().decode(SessionDiagnosticReport.self, from: data),
                  (try? report.validate()) != nil, file.lastPathComponent == report.id.uuidString + ".json",
                  now().timeIntervalSince(report.createdAt) >= 0, now().timeIntervalSince(report.createdAt) <= Self.retention else {
                try? FileManager.default.removeItem(at: file); continue
            }
            reports.append(report)
        }
        reports.sort { $0.createdAt > $1.createdAt }
        for report in reports.dropFirst(Self.maximumReports) { delete(report.id) }
        return Array(reports.prefix(Self.maximumReports))
    }
    func save(_ report: SessionDiagnosticReport) throws {
        try report.validate(); let data = try JSONEncoder().encode(report)
        guard data.count <= 65536 else { throw RemoteError.invalidMessage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(report.id.uuidString + ".json"), options: .atomic)
        _ = load()
    }
    func delete(_ id: UUID) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) }
    func deleteAll() { for report in load() { delete(report.id) } }
}

/// Never changes media/control authority. A test is bound to the exact authenticated peer/epoch.
struct DiagnosticProbeRun {
    enum State: Equatable { case running, completed, cancelled, timedOut }
    let session: UUID
    let epoch: UInt64
    let count: Int
    let started: Double
    private(set) var state = State.running
    private(set) var sent = 0
    private(set) var replies: [Double] = []
    private var outstanding: Set<Double> = []
    private var lastSend = -Double.infinity
    init(session: UUID, epoch: UInt64, full: Bool, at now: Double) {
        self.session = session; self.epoch = epoch; count = full ? 8 : 3; started = now
    }
    mutating func next(session: UUID, epoch: UInt64, authorized: Bool, at now: Double, stampMs: Double) -> ClockProbe? {
        guard state == .running else { return nil }
        guard authorized, self.session == session, self.epoch == epoch, now.isFinite, now >= started else { cancel(); return nil }
        if now - started >= 8 { state = .timedOut; outstanding.removeAll(); return nil }
        guard sent < count, now - lastSend >= 0.5, stampMs.isFinite, stampMs >= 0, !outstanding.contains(stampMs) else { return nil }
        sent += 1; lastSend = now; outstanding.insert(stampMs); return ClockProbe(phoneMs: stampMs)
    }
    mutating func receive(_ echo: ClockProbe, session: UUID, epoch: UInt64, authorized: Bool, at now: Double, stampMs: Double) {
        guard state == .running, authorized, self.session == session, self.epoch == epoch, now >= started, now - started < 8,
              (try? echo.validate()) != nil, echo.isEcho, outstanding.contains(echo.phoneMs),
              stampMs.isFinite, stampMs >= echo.phoneMs, stampMs - echo.phoneMs <= 8000 else { return }
        outstanding.remove(echo.phoneMs)
        replies.append(stampMs - echo.phoneMs)
        if replies.count == count { state = .completed }
    }
    mutating func cancel() { state = .cancelled; outstanding.removeAll() }
    var facts: [DiagnosticFact] { [.init(.authenticatedEchoes, Double(replies.count)), .init(.unansweredEchoes, Double(sent - replies.count)), .init(.applicationRoundTripMs, replies.max())] }
}

/// Session samples are bounded numeric snapshots, not a copy of verbose logs or content.
struct DiagnosticSessionRecorder {
    private(set) var samples = 0
    private var started: TimeInterval?
    private var facts: [DiagnosticFact] = []
    private var bytes = DiagnosticByteLedger()
    mutating func observe(_ report: StreamStatsReport, at now: TimeInterval) {
        guard now.isFinite else { return }; if started == nil { started = now }; samples = min(1000000, samples + 1)
        if let usage = report.transportUsage {
            bytes.observe(.init(generation: usage.generation, at: usage.sampledAt, sent: usage.bytesSent,
                received: usage.bytesReceived, sentKbps: usage.sentKbps, receivedKbps: usage.receivedKbps))
        } else {
            bytes.observe(.init(generation: UUID(), at: now, sent: nil, received: nil, sentKbps: nil, receivedKbps: nil))
        }
        let host = report.role == "host" ? report : nil
        let remote = (report.hostSummaryAgeMs ?? .infinity) <= 2500 ? report.host : nil
        let video = report.role == "host" ? report.sentKbps : report.receivedKbps
        facts = [.init(.videoKbps, video), .init(.videoGBPerHour, video.map { $0 * 0.00045 }, source: .inferred), .init(.networkRoundTripMs, report.rttMs),
            .init(.roundTripSpreadMs, report.rttStdDevMs), .init(.missedFramePercent, report.frameHealthPercent),
            .init(.hostPacerMeanMs, host?.pacerDelayMs ?? remote?.pacerDelayMs), .init(.decodeMeanMs, report.decodeMs),
            .init(.hostEncodeMeanMs, host?.encodeMs ?? remote?.encodeMs),
            .init(.inputPostingP95Ms, host?.inputPostP95Ms ?? remote?.inputPostP95Ms),
            .init(.phoneThermal, report.role == "phone" ? report.thermalState.map(Double.init) : nil),
            .init(.phoneLowPower, report.role == "phone" ? report.lowPowerMode.map { $0 ? 1 : 0 } : nil),
            .init(.hostThermal, host?.thermalState.map(Double.init) ?? remote?.thermalState.map(Double.init)),
            .init(.hostLowPower, (host?.lowPowerMode ?? remote?.lowPowerMode).map { $0 ? 1 : 0 }),
            .init(.routeDirect, report.route == "Direct" ? 1 : report.route == "Relay" ? 0 : nil),
            .init(.routeRelay, report.route == "Relay" ? 1 : report.route == "Direct" ? 0 : nil)]
    }
    func finish(kind: SessionDiagnosticReport.Kind = .session, outcome: SessionDiagnosticReport.Outcome = .sessionEnded,
                at now: TimeInterval, additional: [DiagnosticFact] = []) -> SessionDiagnosticReport {
        let unknown: [DiagnosticFact.Metric] = [.hostScreenRecording, .hostPostEvents, .hostAccessibility, .transportSentBytes, .transportReceivedBytes, .transportGBPerHour, .preEncodeWaitP95Ms, .awdlCause, .billableBytes, .oneOffFileBytes, .guestBytes, .energyJoules, .physicalGlassMs]
        let supplemental = additional + bytes.facts.filter { fact in !additional.contains { $0.metric == fact.metric } }
        let override = Set(supplemental.map(\.metric))
        return SessionDiagnosticReport(kind: kind, outcome: outcome, seconds: now - (started ?? now), samples: samples,
            facts: facts.filter { !override.contains($0.metric) } + supplemental + unknown.filter { !override.contains($0) }.map { DiagnosticFact($0, nil) })
    }
}

/// Counts only differences actually observed on one selected transport generation.
/// No RTP addition (would double count), billing conversion, guest aggregation or gap extrapolation.
struct DiagnosticByteLedger {
    struct Reading {
        let generation: UUID
        let at: Double
        let sent: UInt64?
        let received: UInt64?
        let sentKbps: Double?
        let receivedKbps: Double?
    }
    private var previous: Reading?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var measured = false
    private var complete = true
    private var recentKbps: Double?
    mutating func observe(_ next: Reading) {
        guard next.at.isFinite, let s = next.sent, let r = next.received else { previous = nil; recentKbps = nil; complete = false; return }
        defer { previous = next }
        guard let old = previous else { return }
        guard old.generation == next.generation, let os = old.sent, let or = old.received,
              next.at > old.at, next.at - old.at <= 5, s >= os, r >= or else { recentKbps = nil; complete = false; return }
        let (ns, so) = sent.addingReportingOverflow(s - os), (nr, ro) = received.addingReportingOverflow(r - or)
        guard !so, !ro else { complete = false; recentKbps = nil; return }
        sent = ns; received = nr; measured = true
        if let up = next.sentKbps, let down = next.receivedKbps, up.isFinite, down.isFinite, up >= 0, down >= 0 {
            recentKbps = up + down
        } else { recentKbps = nil }
    }
    var facts: [DiagnosticFact] {
        [.init(.transportSentBytes, measured ? Double(sent) : nil),
         .init(.transportReceivedBytes, measured ? Double(received) : nil),
         .init(.transportGBPerHour, recentKbps.map { $0 * 0.00045 }, source: .inferred),
         .init(.transportIntervalsComplete, measured ? (complete ? 1 : 0) : nil)]
    }
}
