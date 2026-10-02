import XCTest

final class SessionDiagnosticsTests: XCTestCase {
    func testAReportWithMetricsFromANewerBuildLoadsWithoutThem() throws {
        let report = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 12, samples: 3,
                                             facts: [DiagnosticFact(.videoKbps, 200), DiagnosticFact(.curtainCovered, 1)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var facts = try XCTUnwrap(json["facts"] as? [[String: Any]])
        facts.append(["metric": "somethingFromNextYear", "value": 4, "source": "observed"])
        json["facts"] = facts
        let decoded = try JSONDecoder().decode(SessionDiagnosticReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.facts.map(\.metric), [.videoKbps, .curtainCovered], "Unknown metrics are dropped, not fatal")
        XCTAssertEqual(decoded.id, report.id)
        XCTAssertNoThrow(try decoded.validate())
        let roundTrip = try JSONDecoder().decode(SessionDiagnosticReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(roundTrip, report)

        // A fact that is not even an object cannot be skipped; the report is corrupt, never a hang.
        for junk in [NSNull(), 7, "text"] as [Any] {
            json["facts"] = facts + [junk]
            XCTAssertThrowsError(try JSONDecoder().decode(SessionDiagnosticReport.self,
                                                          from: JSONSerialization.data(withJSONObject: json)))
        }
    }

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

    func testSessionMeterSplitsMediaFilesAndOtherAndComparesMeasuredRatesWithEstimate() throws {
        var recorder = DiagnosticSessionRecorder(); let generation = UUID()
        var report = try JSONDecoder().decode(StreamStatsReport.self, from: Data(#"{"role":"phone"}"#.utf8))
        func usage(_ at: Double, _ received: UInt64, media: [String: UInt64]?, files: [String: UInt64]?) -> TransportUsage {
            var usage = TransportUsage(generation: generation, sampledAt: at, bytesSent: 1000, bytesReceived: received,
                                       sentKbps: 0, receivedKbps: 8, coverage: .selectedTransport)
            usage.mediaByEntry = media; usage.fileByEntry = files
            return usage
        }
        let estimate = DataUseEstimate(.sharp, audio: true, packetRepair: false)
        report.transportUsage = usage(10, 0, media: ["v": 0], files: [:]); recorder.observe(report, at: 10, estimate: estimate)
        report.transportUsage = usage(11, 1_000_000, media: ["v": 850_000, "a": 50_000], files: ["f": 50_000]); recorder.observe(report, at: 11)
        report.transportUsage = usage(12, 2_000_000, media: ["v": 1_700_000, "a": 100_000], files: ["f": 100_000]); recorder.observe(report, at: 12)
        let result = recorder.finish(at: 12)
        try result.validate()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("mediaByEntry"), "Stats IDs never reach a log")
        func value(_ metric: DiagnosticFact.Metric) -> Double? { result.facts.first { $0.metric == metric }?.value }
        XCTAssertEqual(value(.mediaRTPBytes), 1_750_000, "The audio entry is a baseline in the interval it appears")
        XCTAssertEqual(value(.oneOffFileBytes), 50_000)
        XCTAssertEqual(value(.otherTransportBytes), 200_000)
        XCTAssertEqual(try XCTUnwrap(value(.transportAverageGBPerHour)), 3.6, accuracy: 1e-9, "2 MB in 2 s is 8 Mb/s")
        XCTAssertEqual(try XCTUnwrap(value(.mediaAverageGBPerHour)), 3.15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value(.estimateHighGBPerHour)), estimate.highGBPerHour, accuracy: 1e-9)
        XCTAssertEqual(result.facts.first { $0.metric == .estimateLowGBPerHour }?.source, .inferred)
        let summary = try XCTUnwrap(result.dataUseSummary)
        for part in ["2.0 MB total", "video + audio 1.8 MB · files 50 KB · other 200 KB", "measured 3.60 GB/hour total",
                     "measured 3.15 GB/hour video + audio", "last preset estimate 0.21–11.28 GB/hour video + audio (repair, files and guests not included)"] {
            XCTAssertTrue(summary.contains(part), summary)
        }
        XCTAssertLessThanOrEqual(result.facts.count, SessionDiagnosticReport.maximumFacts)
    }

    func testMeterShowsTotalOnlyWithoutSplitCountersAndOtherUnknownWhenCountersDisagree() throws {
        var ledger = DiagnosticByteLedger(); let generation = UUID()
        ledger.observe(.init(generation: generation, at: 10, sent: 0, received: 0, sentKbps: nil, receivedKbps: nil, media: [:], files: [:]))
        ledger.observe(.init(generation: generation, at: 11, sent: 0, received: 500, sentKbps: nil, receivedKbps: nil, media: ["v": 400], files: nil))
        XCTAssertEqual(ledger.facts.first { $0.metric == .transportReceivedBytes }?.value, 500)
        XCTAssertNil(ledger.facts.first { $0.metric == .mediaRTPBytes }?.value)
        XCTAssertNil(ledger.facts.first { $0.metric == .oneOffFileBytes }?.value)
        let report = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 1, samples: 2, facts: ledger.facts)
        XCTAssertTrue(try XCTUnwrap(report.dataUseSummary).contains("could not split"))
        XCTAssertTrue(report.preview.contains("could not split"))

        var disagree = DiagnosticByteLedger()
        disagree.observe(.init(generation: generation, at: 10, sent: 0, received: 0, sentKbps: nil, receivedKbps: nil, media: ["v": 0], files: [:]))
        disagree.observe(.init(generation: generation, at: 11, sent: 0, received: 100, sentKbps: nil, receivedKbps: nil, media: ["v": 300], files: [:]))
        XCTAssertEqual(disagree.facts.first { $0.metric == .mediaRTPBytes }?.value, 300)
        XCTAssertNil(disagree.facts.first { $0.metric == .otherTransportBytes }?.value, "A negative remainder is unknown, not zero")
    }
}
