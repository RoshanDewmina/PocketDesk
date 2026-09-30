import XCTest

final class AwayProtocolTests: XCTestCase {
    func testFeatureIsAdvertisedOnlyWhenTheMacAllowsIt() {
        XCTAssertEqual(SessionFeature.away, "away.1")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.away))
    }

    func testAwayStateRoundTripsOnCaptureStatus() throws {
        let status = RemoteAction(action: "capture", away: AwayModeState.covered.rawValue)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(status))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertEqual(AwayModeState(reported: decoded.away), .covered)
    }

    func testUnknownOrMissingAwayMeansOff() {
        XCTAssertEqual(AwayModeState(reported: nil), .off)
        XCTAssertEqual(AwayModeState(reported: "unlocked"), .off)
    }

    func testAwayRidesOnlyOnCapture() {
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", away: "armed").validate())
        XCTAssertThrowsError(try RemoteAction(action: "lockMac", away: "armed").validate())
        XCTAssertThrowsError(try RemoteAction(action: "displays", away: "armed").validate())
    }

    func testLockMacCarriesNoPayload() {
        XCTAssertNoThrow(try RemoteAction(action: "lockMac").validate())
        XCTAssertThrowsError(try RemoteAction(action: "lockMac", text: "x").validate())
        XCTAssertThrowsError(try RemoteAction(action: "lockMac", curtain: "up").validate())
        XCTAssertThrowsError(try RemoteAction(action: "lockMac", x: 1).validate())
        XCTAssertThrowsError(try RemoteAction(action: "lockMac", clipboard: .pull("t")).validate())
    }

    func testOversizedAwayValueIsRejected() {
        XCTAssertThrowsError(try RemoteAction(action: "capture", away: String(repeating: "a", count: 4096)).validate())
    }

    func testOlderDecoderIgnoresTheField() throws {
        let json = #"{"action":"capture","away":"armed","epoch":1,"x":0,"y":0,"text":"","key":"","modifiers":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(RemoteAction.self, from: Data(json.utf8)))
    }

    func testNoticeCopy() {
        XCTAssertEqual(PhoneSessionNotice.awayCovered, "Mac covered · locks if touched")
        XCTAssertEqual(PhoneSessionNotice.awayCantUnlock, "Away mode can’t unlock it.")
    }
}
