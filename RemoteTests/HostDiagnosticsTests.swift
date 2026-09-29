import XCTest

final class DiagnosticsSanitizerTests: XCTestCase {
    func testRemovesAddressesTokensAndIdentifiers() {
        let dirty = """
        Connection service: host_unavailable_or_unauthorized. Check wss://roshans-mac.tail1234.ts.net/signal \
        from 192.168.1.23:8443 and fd7a:115c:a1e0:ab12:4843:cd96:6254:1b2c or ::1, \
        code pocketdesk:eyJ2IjoxLCJrZXkiOiJhYmNkZWYxMjM0NTY3ODkwIn0 for roshan@example.com at \
        /Users/roshansilva/Library/Caches, launch 6F9619FF-8B86-D011-B42D-00C04FC964FF on relay.farside.app
        """
        let clean = DiagnosticsSanitizer.clean(dirty, limit: 2000)
        for secret in ["192.168", "fd7a", "::1", "tail1234", "ts.net", "eyJ2", "roshan@", "roshansilva",
                       "6F9619FF", "farside.app", "wss://"] {
            XCTAssertFalse(clean.contains(secret), "\(secret) leaked: \(clean)")
        }
        XCTAssertTrue(clean.contains("host_unavailable_or_unauthorized"), "Plain error codes stay readable")
        XCTAssertTrue(clean.contains("/Users/[user]/Library/Caches"))
        XCTAssertTrue(clean.contains("[ip]"))
    }

    func testKeepsOrdinaryStatusText() {
        let text = "Direct · video/H264 · 60 fps · 7 ms network RTT · VideoToolbox at 12:04:33"
        XCTAssertEqual(DiagnosticsSanitizer.clean(text), text, "Times and codec readouts are not addresses")
        XCTAssertEqual(DiagnosticsSanitizer.clean(String(repeating: "a", count: 500), limit: 10), "aaaaaaaaaa…")
    }
}

@MainActor
final class HostDiagnosticsReportTests: XCTestCase {
    func testEventLogIsBoundedSanitizedAndDeduplicated() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let log = HostEventLog(now: { clock })
        log.record(.error, "Failed at 10.0.0.2")
        log.record(.error, "Failed at 10.0.0.2")
        XCTAssertEqual(log.entries.count, 1, "Repeats within a few seconds collapse")
        XCTAssertEqual(log.entries.first?.message, "Failed at [ip]")
        for index in 0..<100 {
            clock = clock.addingTimeInterval(10)
            log.record(.session, "Session \(index)")
        }
        XCTAssertEqual(log.entries.count, HostEventLog.capacity)
        XCTAssertEqual(log.entries.last?.message, "Session 99")
    }

    func testReportCoversSupportFactsAndNothingPrivate() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var snapshot = HostDiagnosticsSnapshot()
        snapshot.generatedAt = now
        snapshot.appVersion = "0.1"
        snapshot.appBuild = "20260929.1"
        snapshot.osVersion = "Version 27.0 (Build 26A428)"
        snapshot.hardwareModel = "Mac16,12"
        snapshot.screenRecording = "allowed"
        snapshot.accessibility = "allowed"
        snapshot.loginItem = HostBackgroundItemState.on.diagnosticsText
        snapshot.automaticRecovery = HostBackgroundItemState.needsApproval.diagnosticsText
        snapshot.status = "Your phone is controlling this Mac"
        snapshot.serviceEnvironment = "staging"
        snapshot.localPairRemovalFailure = "delete:-25308"
        snapshot.detail = "Pair with code pocketdesk:c29tZS1wcml2YXRlLXBhaXJpbmctY29kZTEyMzQ1Ng via wss://mac.example.ts.net"
        snapshot.curtainPreference = true
        snapshot.curtainState = PrivacyCurtainState.up.rawValue
        snapshot.recoveredThisLaunch = true
        snapshot.previousExit = "hang"
        snapshot.watchdogRelaunchesThisBoot = 2
        snapshot.watchdogLastExit = "hang"
        snapshot.watchdogLastExitAt = now.addingTimeInterval(-90)
        snapshot.sessionsThisLaunch = 3
        snapshot.lastSessionDuration = 725
        snapshot.route = "Relay · video/H264 · 30 fps · 80 ms network RTT · VideoToolbox"
        snapshot.events = [HostEventLog.Entry(at: now.addingTimeInterval(-30), kind: .recovery,
                                              message: "Restarted after the previous run ended unexpectedly (hang)")]
        let report = HostDiagnosticsReport.render(snapshot)

        for expected in ["Service environment: staging", "Local pairing removal: delete:-25308", "Farside Mac diagnostics", "Version: 0.1 (20260929.1)", "Screen Recording: allowed",
                         "Automatic recovery: needs approval in Login Items", "Curtain: up",
                         "Restarted after a problem: yes (hang)", "Watchdog relaunches this boot: 2",
                         "Last unexpected exit: hang, 1m 30s ago", "Last session length: 12m 5s",
                         "Route: Relay · video/H264", "-30s recovery: Restarted after the previous run ended unexpectedly (hang)"] {
            XCTAssertTrue(report.contains(expected), "Missing \(expected)\n\(report)")
        }
        for secret in ["c29tZS1w", "ts.net", "wss://"] {
            XCTAssertFalse(report.contains(secret), "\(secret) leaked into the report")
        }
    }
}
