import XCTest
@testable import PocketDeskRemote

final class PhoneCrashDiagnosticsTests: XCTestCase {
    func testRetainedServiceStartsOnceAndOnlyExplicitlyExportsSanitizedEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PhoneFixtureDiagnosticSource()
        let diagnostics = CrashDiagnostics(enabled: true, store: CrashDiagnosticStore(directory: directory), source: { source })
        diagnostics.start(); diagnostics.start()
        XCTAssertEqual(source.starts, 1)
        let now = Date()
        source.deliver?(.init(kind: .hang, begin: now, end: now,
            stack: .legacyJSON(Data(#"{"callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":"room-secret","address":"192.0.2.1","offsetIntoBinaryTextSegment":12}]}]}}"#.utf8)), durationSeconds: 1.2))
        let report = try XCTUnwrap(diagnostics.reports().first)
        let export = try XCTUnwrap(diagnostics.export(id: report.id))
        XCTAssertEqual(try JSONDecoder().decode(CrashDiagnosticReport.self, from: export), report)
        XCTAssertEqual(report.event.stack.frames.first?.offsetIntoBinaryTextSegment, 12)
        let text = try XCTUnwrap(String(data: export, encoding: .utf8))
        XCTAssertFalse(text.contains("room-secret")); XCTAssertFalse(text.contains("192.0.2.1"))
        diagnostics.deleteAll(); XCTAssertTrue(diagnostics.reports().isEmpty)
        diagnostics.stop()
        source.deliver?(.init(kind: .crash, begin: now, end: now, stack: .empty))
        XCTAssertTrue(diagnostics.reports().isEmpty)
    }

    func testDisabledServiceDoesNotCreateSubscriberOrPayloadDirectory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PhoneFixtureDiagnosticSource()
        let diagnostics = CrashDiagnostics(enabled: false, store: CrashDiagnosticStore(directory: directory), source: { source })
        diagnostics.start()
        XCTAssertEqual(source.starts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

private final class PhoneFixtureDiagnosticSource: CrashDiagnosticSource {
    var starts = 0
    var deliver: ((CrashDiagnosticEvent) -> Void)?
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) { starts += 1; deliver = receive }
    func stop() {}
}
