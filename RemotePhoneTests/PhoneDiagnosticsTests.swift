import XCTest
@testable import PocketDeskRemote

@MainActor
final class PhoneDiagnosticsTests: XCTestCase {
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
