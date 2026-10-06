import XCTest
import SwiftUI
@testable import PocketDeskRemote

final class ConnectionQualityPhoneTests: XCTestCase {
    func testBannerOnlyShowsConnectedTroubleAndDismissalSticksAcrossAQuietSpell() {
        let verdict = ConnectionQualityVerdict(cause: .relay, lossPercent: 30)
        func content(_ connected: Bool, verdict: ConnectionQualityVerdict?,
                     dismissed: Set<QualityBannerContent.Key> = []) -> QualityBannerContent? {
            QualityBannerContent.make(connected: connected, verdict: verdict, stall: WiFiStallTip(),
                                      dismissed: dismissed, device: "iPhone")
        }
        XCTAssertNil(content(false, verdict: verdict))
        XCTAssertEqual(content(true, verdict: verdict)?.key, .poor(.relay))
        let dismissed: Set<QualityBannerContent.Key> = [.poor(.relay), .stall]
        XCTAssertNil(content(true, verdict: verdict, dismissed: dismissed))
        XCTAssertNil(content(true, verdict: nil, dismissed: dismissed))
        XCTAssertNil(content(true, verdict: verdict, dismissed: dismissed), "the same cause stays hidden after quality clears and returns")
        let other = ConnectionQualityVerdict(cause: .macOnWiFi, lossPercent: 40)
        XCTAssertEqual(content(true, verdict: other, dismissed: dismissed)?.key, .poor(.macOnWiFi))
        XCTAssertEqual(content(true, verdict: nil)?.key, .stall)
    }

    func testLatchedRoundTripHoldBandAndPicturePriority() {
        var evidence = ConnectionHealth.SessionEvidence(connected: true, fresh: true, captureHealthy: true,
                                                         slowRoundTripMs: 130)
        XCTAssertEqual(ConnectionHealth.session(evidence)?.state, .networkSlow)
        evidence.quality = ConnectionQualityVerdict(cause: .unknown, lossPercent: 31)
        XCTAssertEqual(ConnectionHealth.session(evidence)?.state, .framesLost)
        XCTAssertEqual(ConnectionHealth.session(evidence)?.isSlowOnly, false)
        evidence.blocker = .accessibilityOff
        XCTAssertEqual(ConnectionHealth.session(evidence)?.state, .accessibilityOff)
        evidence.fresh = false
        XCTAssertEqual(ConnectionHealth.session(evidence)?.state, .pictureStalled)
    }
}

@MainActor
final class ConnectionQualityResumeSceneTests: XCTestCase {
    func testBackgroundToInactiveKeepsHoldShieldedUntilActiveWithoutAnotherBackgroundRequest() throws {
        let background = FakeBackgroundExecution()
        let model = PhoneRemoteModel(background: background)
        model.sceneChanged(.active)
        model.connection.connected = true
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1,
                                                  features: [SessionFeature.backgroundPause])))
        model.sceneChanged(.background)
        let requests = background.begins
        model.sceneChanged(.inactive)
        XCTAssertEqual(background.begins, requests)
        XCTAssertTrue(model.privacyShield)
        XCTAssertTrue(background.isActive, "Inactive is still shielded background continuity, not a foreground return")
        XCTAssertTrue(model.contentConcealed)
        XCTAssertNil(model.lastResume)
        XCTAssertFalse(model.canControl)
        model.sceneChanged(.background)
        XCTAssertTrue(model.contentConcealed, "an interrupted return is concealed again")
        XCTAssertNil(model.lastResume, "a half-return is never reported as a completed slow return")
        model.sceneChanged(.active)
        XCTAssertFalse(background.isActive, "Only actual foreground return releases the existing hold")
        XCTAssertFalse(model.privacyShield)
        model.disconnect()
    }
}
