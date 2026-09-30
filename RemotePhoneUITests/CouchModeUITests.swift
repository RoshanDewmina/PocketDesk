import XCTest

final class CouchModeUITests: XCTestCase {
    @MainActor
    func testCouchSurfaceShowsTheTrackpadCardAndKeyRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-couch", "--ui-demo-mac"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Look at your Mac. This is its trackpad."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The picture is the one on your wall."].exists)
        for id in ["remote.couch.keys", "remote.couch.mic", "remote.couch.clip", "remote.couch.picture", "remote.couch.controls"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        XCTAssertFalse(app.buttons["Fit whole display"].exists, "Couch has no picture to fit")
        XCTAssertTrue(app.buttons["End session"].exists)
        app.buttons["remote.couch.controls"].tap()
        XCTAssertTrue(app.buttons["Double-click"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remote.displayRow"].exists)
        XCTAssertFalse(app.switches["remote.macCurtain"].exists)
    }

    @MainActor
    func testHomeOffersCouchModeUnderConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac"]
        app.launch()
        let couch = app.buttons["home.couch"]
        XCTAssertTrue(couch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Trackpad and keys. No picture."].exists)
    }
}
