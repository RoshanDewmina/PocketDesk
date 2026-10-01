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
             oneOffFileBytes, guestBytes, energyJoules, physicalGlassMs, mediaRTPBytes, otherTransportBytes,
             transportAverageGBPerHour, estimateLowGBPerHour, estimateHighGBPerHour
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
            case .oneOffFileBytes: "One-off file channel bytes, both directions"
            case .guestBytes: "Other guest peer total (not counted by this peer)"
            case .energyJoules: "Measured energy joules"
            case .physicalGlassMs: "Calibrated physical glass-to-glass ms"
            case .mediaRTPBytes: "Video + audio RTP bytes, both directions"
            case .otherTransportBytes: "Other transport bytes (control, pointer, RTCP, DTLS/SCTP/ICE)"
            case .transportAverageGBPerHour: "Measured average peer transport GB/hour"
            case .estimateLowGBPerHour: "Preset estimate GB/hour, still screen"
            case .estimateHighGBPerHour: "Preset estimate GB/hour, sustained motion"
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
    static let maximumFacts = 48
    init(kind: Kind, outcome: Outcome, seconds: Double, samples: Int, facts: [DiagnosticFact], at: Date = Date()) {
        version = 1; id = UUID(); artifact = .current; createdAt = at; self.kind = kind; self.outcome = outcome
        self.seconds = seconds.isFinite ? min(86400, max(0, seconds)) : 0
        self.samples = min(1000000, max(0, samples)); self.facts = Array(facts.prefix(Self.maximumFacts))
    }
    var preview: String {
        (["Farside local diagnostics · \(kind.rawValue) · \(outcome.rawValue)",
          artifact?.line ?? "Artifact unknown",
          "Report window \(Int(seconds))s · \(samples) samples. No screen, text, host name, address or pairing identifiers.",
          "Observed facts describe this artifact/session; inferred causes are suggestions. Unknown does not mean zero.",
          "Transport payload is not carrier billing or IP/wire overhead. Video RTP excludes other streams. GB is decimal.",
          "Preflight measures bounded authenticated app echoes and current health, not throughput or physical latency."]
         + [dataUseSummary].compactMap { $0 } + facts.map(\.line)).joined(separator: "\n")
    }
    private func value(_ metric: DiagnosticFact.Metric) -> Double? { facts.first { $0.metric == metric }?.value }
    /// Measured session bytes beside the preset's modelled range, so the two can be compared.
    var dataUseSummary: String? {
        guard let sent = value(.transportSentBytes), let received = value(.transportReceivedBytes) else { return nil }
        func size(_ bytes: Double) -> String { bytes >= 1e9 ? String(format: "%.2f GB", bytes / 1e9) : String(format: "%.1f MB", bytes / 1e6) }
        var parts = ["Data used \(size(sent + received)) total"]
        if let media = value(.mediaRTPBytes), let files = value(.oneOffFileBytes), let other = value(.otherTransportBytes) {
            parts.append("video + audio \(size(media)) · files \(size(files)) · other \(size(other))")
        } else {
            parts.append("these counters could not split video and audio from files, so only the total is shown")
        }
        if let average = value(.transportAverageGBPerHour) { parts.append(String(format: "measured %.2f GB/hour", average)) }
        if let low = value(.estimateLowGBPerHour), let high = value(.estimateHighGBPerHour) {
            parts.append(String(format: "preset estimate %.2f–%.2f GB/hour (files and guests not included)", low, high))
        }
        return parts.joined(separator: " · ") + "."
    }
    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite, seconds.isFinite, (0...86400).contains(seconds),
              (0...1000000).contains(samples), facts.count <= Self.maximumFacts, artifact?.valid ?? true,
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

