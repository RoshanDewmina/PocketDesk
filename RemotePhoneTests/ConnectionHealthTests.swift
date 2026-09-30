import XCTest
@testable import PocketDeskRemote

final class ConnectionHealthTests: XCTestCase {
    private let everyFailure: [FriendlyError] = [
        .napping(since: "11:48 PM"), .napping(since: nil), .locked(since: nil), .switchedUser(since: nil),
        .unreachable("Studio Mac"), .screenSharingOff, .busy, .needsPlan, .anywhereUnverified, .codeRejected,
        .declined, .approvalTimedOut, .verifyFailed, .keychain, .relayUnavailable, .serviceNotReady,
        .connectionLost, .sessionGlitch
    ]

    func testEveryFailureBecomesOneStateWithOneNextStep() {
        for failure in everyFailure {
            let health = ConnectionHealth.after(failure)
            XCTAssertFalse(health.title.isEmpty, "\(failure.kind)")
            XCTAssertFalse(health.detail.isEmpty, "\(failure.kind)")
            XCTAssertFalse(health.nextStep.isEmpty, "\(failure.kind)")
            XCTAssertFalse(health.nextStep.contains("\n"), "One next step, not a list: \(failure.kind)")
        }
    }

    func testSilenceIsNeverGivenACause() {
        for failure in [FriendlyError.unreachable("Studio Mac"), .connectionLost] {
            let health = ConnectionHealth.after(failure)
            XCTAssertEqual(health.state, .unreachable)
            XCTAssertTrue(health.causeUnknown)
            XCTAssertEqual(health.title, "Unreachable · cause unknown")
            XCTAssertEqual(health.action, .checkAgain, "An unknown cause offers a check, not a guess")
        }
        let silent = ConnectionHealth.checked(.notAnswering, lastReached: nil)
        XCTAssertEqual(silent.state, .unreachable, "A refusal from the service is not proof the Mac is asleep")
        XCTAssertNotEqual(silent.state, .macAsleep)
    }

    func testTheMacsOwnReportNamesTheCause() {
        let asleep = ConnectionHealth.after(.napping(since: "11:48 PM"))
        XCTAssertEqual(asleep.state, .macAsleep)
        XCTAssertEqual(asleep.title, "Mac asleep")
        XCTAssertTrue(asleep.detail.contains("11:48 PM"))
        XCTAssertEqual(asleep.nextStep, FriendlyError.napping(since: nil).fix)
        XCTAssertFalse(asleep.causeUnknown)
        XCTAssertEqual(ConnectionHealth.after(.locked(since: nil)).state, .macLocked)
        XCTAssertEqual(ConnectionHealth.after(.switchedUser(since: nil)).state, .otherUser)
    }

    func testTheServiceAskingForAnywhereOffersThePlan() {
        let health = ConnectionHealth.after(.needsPlan)
        XCTAssertEqual(health.state, .needsAnywhere)
        XCTAssertEqual(health.title, "Different network · Anywhere needed")
        XCTAssertEqual(health.action, .seePlans)
        XCTAssertEqual(ConnectionHealth.after(.anywhereUnverified).state, .anywhereUnconfirmed)
    }

    func testAStoppedCaptureDoesNotClaimAPermissionItCannotSee() {
        let health = ConnectionHealth.after(.screenSharingOff)
        XCTAssertEqual(health.state, .sharingStopped)
        XCTAssertFalse(health.title.contains("Screen Recording"), "The Mac reports a stopped capture, not its cause")
        XCTAssertTrue(health.nextStep.contains("Screen Recording"), "Checking it is still the most useful next step")
        XCTAssertEqual(health.action, .none, "Only someone at the Mac can fix it")
    }

    func testReachabilityCheckOutcomes() {
        XCTAssertEqual(ConnectionHealth.checked(.answering, lastReached: nil).state, .macAnswering)
        let silent = ConnectionHealth.checked(.notAnswering, lastReached: "yesterday 11:48 PM")
        XCTAssertTrue(silent.detail.contains("Last reached yesterday 11:48 PM."))
        XCTAssertEqual(ConnectionHealth.checked(.sessionBusy, lastReached: nil).state, .macBusy)
        let offline = ConnectionHealth.checked(.serviceUnreachable, lastReached: nil)
        XCTAssertEqual(offline.state, .serviceUnreachable)
        XCTAssertTrue(offline.nextStep.contains("this iPhone is online"))
    }

    private func session(connected: Bool = true, fresh: Bool = true, capture: Bool = true,
                         presence: HostPresence? = nil, wake: Bool = false,
                         route: String? = "Direct", rtt: Int? = 12) -> ConnectionHealth? {
        ConnectionHealth.session(.init(connected: connected, fresh: fresh, captureHealthy: capture,
                                       hostPresence: presence, canWakeDisplay: wake, route: route, roundTripMs: rtt))
    }

    func testAHealthySessionReportsNothing() {
        XCTAssertNil(session())
        XCTAssertNil(session(route: nil, rtt: nil))
        XCTAssertNil(session(route: "Relay", rtt: ConnectionHealth.slowRoundTripMs - 1))
    }

    func testSessionStatesComeFromWhatWasObserved() {
        XCTAssertEqual(session(connected: false)?.state, .reconnecting)
        XCTAssertEqual(session(presence: .displayAsleep, wake: true)?.action, .wakeDisplay)
        XCTAssertEqual(session(presence: .displayAsleep, wake: false)?.action, ConnectionHealth.Action.none)
        let stopped = session(capture: false)
        XCTAssertEqual(stopped?.state, .sharingStopped)
        XCTAssertEqual(stopped?.sessionLine, "Mac stopped sharing its screen · controls paused")
        let stalled = session(fresh: false, capture: false)
        XCTAssertEqual(stalled?.state, .pictureStalled)
        XCTAssertEqual(stalled?.causeUnknown, true)
    }

    func testTheMostExplanatoryEvidenceWins() {
        XCTAssertEqual(session(connected: false, fresh: false, capture: false)?.state, .reconnecting,
                       "A dropped connection explains the stalled picture")
        XCTAssertEqual(session(fresh: false, presence: .displayAsleep)?.state, .displayAsleep,
                       "The Mac's own report beats an unexplained stall")
        XCTAssertEqual(session(capture: false, route: "Relay", rtt: 400)?.state, .sharingStopped,
                       "A stopped capture matters more than a slow route")
    }

    func testSlowRoutesNameTheRouteTheyMeasured() {
        let relay = session(route: "Relay", rtt: 240)
        XCTAssertEqual(relay?.state, .relaySlow)
        XCTAssertEqual(relay?.detail, "Relayed route, 240 ms round trip.")
        XCTAssertEqual(relay?.isSlowOnly, true)
        let direct = session(route: "Direct", rtt: 180)
        XCTAssertEqual(direct?.state, .networkSlow)
        XCTAssertEqual(direct?.detail, "Direct route, 180 ms round trip.")
        XCTAssertEqual(session(route: nil, rtt: 180)?.detail, "180 ms round trip.", "An unknown route is not named")
        XCTAssertEqual(session(capture: false)?.isSlowOnly, false)
    }

    func testTheConnectPromptAsksOnlyAnIdlePairedPhone() {
        XCTAssertEqual(ConnectPromptSheet.macName(paired: "Studio Mac", connected: false, running: false), "Studio Mac")
        XCTAssertNil(ConnectPromptSheet.macName(paired: nil, connected: false, running: false), "Not paired: Home shows pairing")
        XCTAssertNil(ConnectPromptSheet.macName(paired: "Studio Mac", connected: true, running: true))
        XCTAssertNil(ConnectPromptSheet.macName(paired: "Studio Mac", connected: false, running: true))
    }

    func testTheWidgetLinkOpensTheConnectPromptRoute() {
        XCTAssertEqual(FarsideRoute(url: ConnectWidgetLink.url), .openMac)
        XCTAssertEqual(ConnectWidgetLink.url, FarsideRoute.openMac.url)
    }
}
