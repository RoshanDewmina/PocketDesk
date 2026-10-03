import XCTest
@testable import PocketDeskRemote

@MainActor
final class PhoneDiagnosticsTests: XCTestCase {
    private func isolatedCrashes(_ directory: URL) -> CrashDiagnostics {
        CrashDiagnostics(enabled: false, store: CrashDiagnosticStore(directory: directory.appendingPathComponent("crashes")), source: { DiagnosticsFixtureSource() })
    }
    func testCrashCallbackRefreshesExistingExplicitPreviewExportAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DiagnosticsFixtureSource()
        let crashes = CrashDiagnostics(enabled: true, store: CrashDiagnosticStore(directory: directory.appendingPathComponent("crashes")), source: { source })
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory.appendingPathComponent("sessions")), crashes: crashes)
        let now = Date()
        source.deliver?(.init(kind: .hang, begin: now, end: now, stack: .empty, durationSeconds: 1))
        // Combine receive(on:) updates the same Published report list used by DiagnosticReportRows.
        for _ in 0..<20 where diagnostics.reports.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.kind, .appleDiagnostic)
        XCTAssertTrue(report.preview.contains("sanitized local stack"))
        XCTAssertNotNil(diagnostics.exportCrashReport(report.id))
        XCTAssertNoThrow(try report.validate())
        diagnostics.delete(report.id)
        XCTAssertTrue(diagnostics.reports.isEmpty); XCTAssertTrue(crashes.reports().isEmpty)
        crashes.stop()
    }
    func testZeroSampleFailureRetainsOnlyTypedStageReasonAndDurationAndRollbackSkipsIt() throws {
        for enabled in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var now = 10.0
            let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), uptime: { now }, attemptDiagnosticsEnabled: enabled, crashes: isolatedCrashes(directory))
            diagnostics.beginAttempt()
            now = 11; diagnostics.recordAttemptStage(.authenticating)
            now = 13; diagnostics.finishAttempt(reason: .connectionFailed)
            if enabled {
                let report = try XCTUnwrap(diagnostics.reports.first)
                XCTAssertEqual(report.samples, 0); XCTAssertEqual(report.seconds, 3)
                XCTAssertEqual(report.outcome, .failed)
                XCTAssertEqual(report.attempt?.events.map(\.stage), [.requested, .authenticating, .ended])
                XCTAssertEqual(report.attempt?.reason, .connectionFailed)
                XCTAssertTrue(report.preview.contains("connectionFailed"))
                XCTAssertNoThrow(try report.validate())
            } else { XCTAssertTrue(diagnostics.reports.isEmpty) }
            diagnostics.finishAttempt(reason: .connectionFailed)
            XCTAssertEqual(diagnostics.reports.count, enabled ? 1 : 0, "Duplicate lifecycle callbacks must not duplicate a report")
        }
    }

    func testUnfinishedAttemptSurvivesRestartAndNeverImportsRawStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionDiagnosticStore(directory: directory)
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: store, uptime: { now }, attemptDiagnosticsEnabled: true, crashes: isolatedCrashes(directory))
        diagnostics.beginAttempt()
        now = 12; diagnostics.recordAttemptStage(.mediaConnecting)
        let restarted = PhoneDiagnostics(store: store, attemptDiagnosticsEnabled: true, crashes: isolatedCrashes(directory))
        let report = try XCTUnwrap(restarted.reports.first)
        XCTAssertEqual(report.attempt?.reason, .processInterrupted)
        XCTAssertEqual(report.seconds, 2, "Never invent the unsampled time after the last persisted event")
        XCTAssertFalse(report.preview.contains("sessionID"))
        let coordinator = RemoteCoordinator(isHost: false, store: MemoryStore())
        restarted.bind(to: coordinator)
        coordinator.status = "Connecting securely…"
        coordinator.status = "https://secret.invalid/room-private?token=secret"
        let exported = try JSONEncoder().encode(try XCTUnwrap(restarted.reports.first))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("secret"))
    }

    func testAttemptDefaultSwitchIsOnAndExplicitNoRestoresLegacy() {
        let name = "PhoneDiagnosticsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(PhoneDiagnostics.attemptDiagnosticsEnabled(defaults: defaults))
        defaults.set(false, forKey: PhoneDiagnostics.attemptDiagnosticsKey)
        XCTAssertFalse(PhoneDiagnostics.attemptDiagnosticsEnabled(defaults: defaults))
    }
    func testUpdatingAttemptAtRetentionCapPreservesOtherReportsAndItsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionDiagnosticStore(directory: directory)
        var history: Set<UUID> = []
        for index in 1..<SessionDiagnosticStore.maximumReports {
            let report = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 1, samples: 1,
                facts: [], at: Date().addingTimeInterval(-Double(index)))
            history.insert(report.id); try store.save(report)
        }
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: store, uptime: { now }, attemptDiagnosticsEnabled: true, crashes: isolatedCrashes(directory))
        diagnostics.beginAttempt()
        let id = try XCTUnwrap(diagnostics.reports.first { $0.kind == .connectionAttempt }?.id)
        now = 11; diagnostics.recordAttemptStage(.authenticating)
        now = 12; diagnostics.recordAttemptStage(.mediaConnecting)
        now = 13; diagnostics.finishAttempt(reason: .connectionFailed)
        XCTAssertEqual(diagnostics.reports.count, SessionDiagnosticStore.maximumReports)
        XCTAssertEqual(Set(diagnostics.reports.filter { $0.kind == .session }.map(\.id)), history)
        XCTAssertEqual(diagnostics.reports.first { $0.kind == .connectionAttempt }?.id, id)
    }
    func testCoordinatorRetryBeforeConnectIsFailedAndLiveLossIsEndedWithRollback() throws {
        for enabled in [true, false] {
            for wasConnected in [true, false] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                var now = 10.0
                let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), uptime: { now },
                    attemptDiagnosticsEnabled: enabled, crashes: isolatedCrashes(directory))
                let trust = MemoryStore()
                try trust.save(TestPairing.invitation())
                let signaling = FakeSignalingTransport()
                let coordinator = RemoteCoordinator(isHost: false, store: trust, signaling: signaling)
                defer { coordinator.stop() }
                coordinator.restore()
                diagnostics.bind(to: coordinator)
                coordinator.start()
                XCTAssertTrue(coordinator.isRunning)
                now = 11; coordinator.status = "Authenticating your Mac…"
                if wasConnected { coordinator.connected = true }
                now = 12; signaling.onClose?()
                XCTAssertTrue(coordinator.reconnecting)
                if enabled {
                    let report = try XCTUnwrap(diagnostics.reports.first)
                    XCTAssertEqual(report.samples, 0)
                    if wasConnected {
                        XCTAssertEqual(report.attempt?.reason, .connectionEnded)
                        XCTAssertEqual(report.outcome, .sessionEnded)
                    } else {
                        // A loss before connecting is a retry inside the same attempt, not a new report.
                        XCTAssertNil(report.attempt?.reason)
                        XCTAssertEqual(report.outcome, .inProgress)
                        XCTAssertEqual(report.attempt?.events.last?.stage, .retrying)
                    }
                    XCTAssertEqual(report.seconds, 2)
                } else { XCTAssertTrue(diagnostics.reports.isEmpty) }
            }
        }
    }
    func testRetriesWithinOneOutageShareOneAttemptReportAndKeepEarlierReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionDiagnosticStore(directory: directory)
        let session = SessionDiagnosticReport(kind: .session, outcome: .sessionEnded, seconds: 30, samples: 30, facts: [],
                                              at: Date().addingTimeInterval(-120))
        let testMyMac = SessionDiagnosticReport(kind: .fullPreflight, outcome: .completed, seconds: 10, samples: 10, facts: [],
                                                at: Date().addingTimeInterval(-60))
        try store.save(session); try store.save(testMyMac)
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: store, uptime: { now }, attemptDiagnosticsEnabled: true, crashes: isolatedCrashes(directory))
        let trust = MemoryStore()
        try trust.save(TestPairing.invitation())
        let signaling = FakeSignalingTransport()
        let coordinator = RemoteCoordinator(isHost: false, store: trust, sessionLossRetryLimit: 24, signaling: signaling)
        defer { coordinator.stop() }
        coordinator.restore()
        diagnostics.bind(to: coordinator)
        coordinator.start()
        for retry in 1...24 {
            // start() already published the first "Connecting securely…"; later ones are the retries.
            if retry > 1 { now += 1; coordinator.status = "Connecting securely…" }
            now += 1; coordinator.status = "Authenticating your Mac…"
            now += 1; signaling.onClose?()
            XCTAssertTrue(coordinator.isRunning, "retry \(retry) stays within the retry budget")
        }
        let attempts = diagnostics.reports.filter { $0.kind == .connectionAttempt }
        XCTAssertEqual(attempts.count, 1, "One outage is one attempt record, however many retries it took")
        XCTAssertEqual(attempts.first?.outcome, .inProgress)
        XCTAssertTrue(attempts.first?.attempt?.events.contains { $0.stage == .retrying } == true)
        XCTAssertLessThanOrEqual(attempts.first?.attempt?.events.count ?? 0, DiagnosticAttemptSummary.maximumEvents)
        XCTAssertTrue(diagnostics.reports.contains { $0.id == session.id }, "The session report survives a 24-retry outage")
        XCTAssertTrue(diagnostics.reports.contains { $0.id == testMyMac.id }, "So does the Test My Mac report")
        XCTAssertEqual(store.load().count, 3)
    }

    func testTerminalFailureAfterConnectingIsRecordedAsASessionThatEnded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), uptime: { now },
            attemptDiagnosticsEnabled: true, crashes: isolatedCrashes(directory))
        let trust = MemoryStore()
        try trust.save(TestPairing.invitation())
        let signaling = FakeSignalingTransport()
        let coordinator = RemoteCoordinator(isHost: false, store: trust, signaling: signaling)
        defer { coordinator.stop() }
        coordinator.restore()
        diagnostics.bind(to: coordinator)
        coordinator.start() // publishes "Connecting securely…" at 10
        now = 12; coordinator.connected = true
        now = 14; signaling.onMessage?(RelayMessage(type: "route")) // unverifiable route: terminal on the phone
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNotEqual(coordinator.status, "Disconnected")
        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.attempt?.reason, .connectionEnded, "A session that connected and then failed terminally ended; it did not fail to connect")
        XCTAssertEqual(report.outcome, .sessionEnded)
        XCTAssertEqual(report.seconds, 4)
    }

    func testPreflightUsesOnlyItsOwnCounterBaselineAndSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = 10.0
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), uptime: { now }, crashes: isolatedCrashes(directory))
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
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), crashes: isolatedCrashes(directory))
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
        let diagnostics = PhoneDiagnostics(store: SessionDiagnosticStore(directory: directory), crashes: isolatedCrashes(directory))
        var authority = true, sends = 0
        diagnostics.start(full: false, session: UUID(), epoch: 7, authorized: { authority }, send: { _ in sends += 1; return true }, facts: { [] })
        authority = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sends, 0); XCTAssertFalse(diagnostics.running)
        XCTAssertEqual(diagnostics.reports.first?.outcome, .cancelled)
    }
}

private final class DiagnosticsFixtureSource: CrashDiagnosticSource {
    var deliver: ((CrashDiagnosticEvent) -> Void)?
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) { deliver = receive }
    func stop() {}
}
