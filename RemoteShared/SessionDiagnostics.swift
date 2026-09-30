import Foundation

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
