import XCTest
@testable import PocketDeskRemote

@MainActor
final class PhoneDiagnosticsTests: XCTestCase {
    func testPreflightUsesOnlyItsOwnCounterBaselineAndSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), uptime: { now })
        let generation = UUID()
        func observe(_ bytes: UInt64) throws {
            var report = try JSONDecoder().decode(StreamStatsReport.self, from: Data("{\"role\":\"phone\"}".utf8))
            report.transportUsage = TransportUsage(generation: generation, sampledAt: now, bytesSent: bytes, bytesReceived: bytes,
                sentKbps: 1, receivedKbps: 1, coverage: .selectedTransport)
            diagnostics.observe(report)
        }
        try observe(100); now = 11; try observe(1000)
        now = 100
        diagnostics.start(full: false, session: UUID(), epoch: 7, authorized: { true }, send: { _ in true }, facts: { [] })
        now = 100.5; try observe(10000)
        now = 101; try observe(10050)
        now = 101.5; diagnostics.cancel()
        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.kind, .lightPreflight); XCTAssertEqual(report.seconds, 1.5); XCTAssertEqual(report.samples, 2)
        XCTAssertEqual(report.facts.first { $0.metric == .transportSentBytes }?.value, 50)
        diagnostics.ended()
        let session = try XCTUnwrap(diagnostics.reports.first { $0.kind == .session })
        XCTAssertEqual(session.samples, 4); XCTAssertEqual(session.seconds, 91.5)
    }

    func testActualControllerCancelsQueuedProbeAndRetainsDeletableReportWithoutSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory))
        var sends = 0
        diagnostics.start(full: true, session: UUID(), epoch: 7, authorized: { true }, send: { _ in sends += 1; return true }, facts: { [] })
        diagnostics.cancel()
        await Task.yield()
        XCTAssertEqual(sends, 0); XCTAssertFalse(diagnostics.running)
        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.outcome, .cancelled)
        diagnostics.delete(report.id); XCTAssertTrue(diagnostics.reports.isEmpty)
    }
    func testAuthorityLossStopsProductionTaskBeforeEchoAndDoesNotClaimPassed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory))
        var authority = true, sends = 0
        diagnostics.start(full: false, session: UUID(), epoch: 7, authorized: { authority }, send: { _ in sends += 1; return true }, facts: { [] })
        authority = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sends, 0); XCTAssertFalse(diagnostics.running)
        XCTAssertEqual(diagnostics.reports.first?.outcome, .cancelled)
    }
}
