import XCTest

@MainActor
final class AppInteractionTests: XCTestCase {
    func testMalformedPairingCodeKeepsDemoAvailable() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["connectionButton"].tap()
        let field = app.textFields["pairingCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("invalid-code")
        app.buttons["connectMac"].tap()
        XCTAssertTrue(app.staticTexts["Paste the complete connection code from your Mac."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["keyboardMode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo workspace · no Mac connected"].exists)
    }
    func testTypingAndLayout() throws {
        let app = XCUIApplication()
        app.launch()
        let keyboard = app.buttons["keyboardMode"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        let clear = app.buttons["clearDocument"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "Keyboard must respond to a real tap")
        clear.tap()
        app.buttons["h"].tap()
        app.buttons["i"].tap()
        XCTAssertTrue(app.staticTexts["demoDocument"].label.contains("hi"))
        app.buttons["layoutToggle"].tap()
        XCTAssertTrue(app.buttons["Laptop"].waitForExistence(timeout: 5))
    }
}
