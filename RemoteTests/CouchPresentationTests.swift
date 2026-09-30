import XCTest

final class CouchPresentationTests: XCTestCase {
    private func state(_ status: HostStatus, couch: Bool) -> HostViewState {
        var state = HostViewState()
        state.status = status
        state.couchMode = couch
        return state
    }

    func testCouchPopoverSaysNoPictureIsSharedAndKeepsStopSharing() {
        let presentation = HostPopoverPresentation.make(for: state(.controlling, couch: true))
        XCTAssertEqual(presentation.mood, .live)
        XCTAssertEqual(presentation.headline, "Couch mode · no picture shared")
        XCTAssertEqual(presentation.title, "Your iPhone is steering")
        XCTAssertEqual(presentation.actions, [.pause, .stopSharing])
        XCTAssertEqual(presentation.emphasis(of: .stopSharing), .ember)
    }

    func testCouchWithControlOffSaysSo() {
        let presentation = HostPopoverPresentation.make(for: state(.viewing, couch: true))
        XCTAssertEqual(presentation.headline, "Couch mode · control is off")
        XCTAssertEqual(presentation.title, "Your iPhone is connected")
    }

    func testPictureSessionsAreUnchanged() {
        let steering = HostPopoverPresentation.make(for: state(.controlling, couch: false))
        XCTAssertEqual(steering.headline, "Connected · sharing this Mac")
        XCTAssertEqual(steering.title, "Your iPhone is steering")
        let watching = HostPopoverPresentation.make(for: state(.viewing, couch: false))
        XCTAssertEqual(watching.headline, "Connected · view only")
        XCTAssertEqual(watching.title, "Your iPhone is watching")
    }

    func testTheMenuBarTipIsEmberWhileAnyPhoneIsConnected() {
        XCTAssertEqual(HostMarkState(status: .controlling), .live)
        XCTAssertEqual(HostMarkState(status: .viewing), .live)
        XCTAssertEqual(CouchCopy.hud, "iPhone is steering this Mac · Couch mode, no picture shared")
    }
}
