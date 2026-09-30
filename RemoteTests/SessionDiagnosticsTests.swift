import XCTest

final class SessionDiagnosticsTests: XCTestCase {
    func testProbeBoundedSpacingBindingDuplicatesCancelAndTimeout() {
        let session = UUID(); var run = DiagnosticProbeRun(session: session, epoch: 7, full: false, at: 10)
        XCTAssertNotNil(run.next(session: session, epoch: 7, authorized: true, at: 10, stampMs: 10000))
        XCTAssertNil(run.next(session: session, epoch: 7, authorized: true, at: 10.1, stampMs: 10100))
        let echo = ClockProbe(phoneMs: 10000, hostReceivedMs: 20000, hostSentMs: 20001)
        run.receive(echo, session: UUID(), epoch: 7, authorized: true, at: 10.2, stampMs: 10200)
        XCTAssertTrue(run.replies.isEmpty)
        run.receive(echo, session: session, epoch: 7, authorized: true, at: 10.2, stampMs: 10200)
        run.receive(echo, session: session, epoch: 7, authorized: true, at: 10.3, stampMs: 10300)
        XCTAssertEqual(run.replies, [200])
        XCTAssertNil(run.next(session: session, epoch: 8, authorized: true, at: 10.5, stampMs: 10500)); XCTAssertEqual(run.state, .cancelled)
        var full = DiagnosticProbeRun(session: session, epoch: 7, full: true, at: 10)
        for index in 0..<20 { _ = full.next(session: session, epoch: 7, authorized: true, at: 10 + Double(index) * 0.5, stampMs: 10000 + Double(index) * 500) }
        XCTAssertEqual(full.sent, 8); XCTAssertEqual(full.state, .timedOut)
        full.receive(echo, session: session, epoch: 7, authorized: true, at: 11, stampMs: 11000); XCTAssertTrue(full.replies.isEmpty)
    }
    func testReportRetentionPreviewNoSecretFieldsAndDeletionAreRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var now = Date(timeIntervalSince1970: 1000000)
        let store = SessionDiagnosticStore(directory: dir, now: { now })
        for index in 0..<15 {
            let report = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 1, samples: 2,
                facts: [.init(.videoKbps, 1000), .init(.billableBytes, nil)], at: now.addingTimeInterval(Double(index) - 15))
            try store.save(report)
        }
        XCTAssertEqual(store.load().count, 10)
        let report = try XCTUnwrap(store.load().first)
        XCTAssertTrue(report.preview.contains("billable bytes: unknown")); XCTAssertFalse(report.preview.contains("hostRecordID"))
        store.delete(report.id); XCTAssertEqual(store.load().count, 9)
        now = now.addingTimeInterval(8 * 86400); XCTAssertTrue(store.load().isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let malformed = dir.appendingPathComponent("bad.json"); try Data(repeating: 65, count: 65537).write(to: malformed)
        XCTAssertTrue(store.load().isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.path))
        store.deleteAll()
    }
    func testNumericEvidenceNeverInventsUnknownOrAcceptsDuplicateAndNaN() throws {
        XCTAssertEqual(DiagnosticFact(.videoKbps, .nan).source, .unknown)
        XCTAssertEqual(DiagnosticFact(.awdlCause, nil, source: .inferred).source, .unknown)
        XCTAssertEqual(DiagnosticFact(.wifiBurstPossible, 1, source: .inferred).source, .inferred)
        let report = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 1, samples: 1, facts: [.init(.billableBytes, nil), .init(.billableBytes, 0)])
        XCTAssertThrowsError(try report.validate())
        let decoded = try JSONDecoder().decode(SessionDiagnosticReport.self, from: JSONEncoder().encode(SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 1, samples: 1, facts: [.init(.physicalGlassMs, nil)])))
        XCTAssertTrue(decoded.preview.contains("physical glass-to-glass ms: unknown"))
    }
    func testMeteredHintDoesNotDisappearBehindWeakWifiOrConstrainedAndDoesNotClassifyRoute() {
        XCTAssertTrue(NetworkLinkHint.from(.init(quality: .minimal, expensive: true, wifi: true))?.metered == true)
        XCTAssertTrue(NetworkLinkHint.from(.init(ultraConstrained: true, cellular: true))?.metered == true)
        XCTAssertNil(NetworkLinkHint.from(.init(wifi: true)))
    }
    func testCumulativeTransportIsNotVideoSumAndResetGapsCannotInventHourlyUsage() {
        var ledger = DiagnosticByteLedger(); let generation = UUID()
        func reading(_ at: Double, _ sent: UInt64, _ received: UInt64, generation: UUID) -> DiagnosticByteLedger.Reading {
            .init(generation: generation, at: at, sent: sent, received: received, sentKbps: 8000, receivedKbps: 8000)
        }
        ledger.observe(reading(10, 1000, 2000, generation: generation))
        XCTAssertNil(ledger.facts.first { $0.metric == .transportSentBytes }?.value)
        ledger.observe(reading(11, 2000, 4000, generation: generation))
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportSentBytes }?.value, 1000)
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportReceivedBytes }?.value, 2000)
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportGBPerHour }?.value, 7.2)
        ledger.observe(reading(12, 1, 1, generation: UUID()))
        XCTAssertNil(ledger.facts.first { $0.metric == .transportGBPerHour }?.value)
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportIntervalsComplete }?.value, 0)
        ledger.observe(reading(30, 5000000, 5000000, generation: generation))
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportSentBytes }?.value, 1000, "Unsampled reset/gap bytes never counted")
    }

    func testFullProbeCompletionKeepsAllOutOfOrderRepliesAndMalformedDoesNotConsumePending() {
        let session = UUID(); var run = DiagnosticProbeRun(session: session, epoch: 7, full: true, at: 10)
        for index in 0..<8 { XCTAssertNotNil(run.next(session: session, epoch: 7, authorized: true, at: 10 + Double(index) * 0.5, stampMs: 10000 + Double(index) * 500)) }
        let first = ClockProbe(phoneMs: 10000, hostReceivedMs: 20000, hostSentMs: 20001)
        run.receive(first, session: session, epoch: 7, authorized: true, at: 14, stampMs: .nan)
        for index in (0..<8).reversed() {
            run.receive(ClockProbe(phoneMs: 10000 + Double(index) * 500, hostReceivedMs: 20000, hostSentMs: 20001), session: session, epoch: 7, authorized: true, at: 14, stampMs: 14000)
        }
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.replies.count, 8)
        XCTAssertEqual(run.facts.first { $0.metric == .unansweredEchoes }?.value, 0)
        XCTAssertEqual(run.facts.first { $0.metric == .applicationRoundTripMs }?.value, 4000)
    }

    func testProductionRecorderUsesRoleVideoAndTransportPayloadWithoutPersistingIdentity() throws {
        var report = try JSONDecoder().decode(StreamStatsReport.self, from: Data(#"{"role":"phone","sentKbps":50,"receivedKbps":1000,"hostSummaryAgeMs":3000,"host":{"encodeMs":12}}"#.utf8))
        let generation = UUID(); var recorder = DiagnosticSessionRecorder()
        report.transportUsage = .init(generation: generation, sampledAt: 10, bytesSent: 100, bytesReceived: 200, sentKbps: nil, receivedKbps: nil, coverage: .selectedTransport)
        recorder.observe(report, at: 10)
        report.transportUsage = .init(generation: generation, sampledAt: 11, bytesSent: 300, bytesReceived: 600, sentKbps: 1.6, receivedKbps: 3.2, coverage: .selectedTransport)
        recorder.observe(report, at: 11)
        let result = recorder.finish(at: 12)
        try result.validate()
        XCTAssertEqual(result.facts.first { $0.metric == .videoKbps }?.value, 1000)
        XCTAssertEqual(result.facts.first { $0.metric == .transportSentBytes }?.value, 200)
        XCTAssertEqual(result.facts.first { $0.metric == .transportReceivedBytes }?.value, 400)
        XCTAssertNil(result.facts.first { $0.metric == .hostEncodeMeanMs }?.value, "Stale remote host summaries stay unknown")
        XCTAssertNil(result.facts.first { $0.metric == .guestBytes }?.value)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(generation.uuidString))
        report.role = "host"; recorder.observe(report, at: 12)
        XCTAssertEqual(recorder.finish(at: 13).facts.first { $0.metric == .videoKbps }?.value, 50)
    }

}
