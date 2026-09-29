import XCTest

final class FarsideRedesignUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testKeyboardBarPutsCommandFirstAndInReachInPortrait() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        app.buttons["Show controls"].doubleTap()
        let command = app.buttons["Command"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.isHittable, "⌘ must be visible without scrolling the key row")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(command.frame), "⌘ sits fully on screen in portrait")
        XCTAssertLessThan(command.frame.minX, app.buttons["Escape"].frame.minX, "Modifiers come first")
        attach("Keyboard bar - modifiers first")
    }

    @MainActor
    func testDockOffersKeysMicClipFitModeSegmentsAndEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        let handle = app.buttons["Show controls"]
        handle.swipeUp()
        XCTAssertTrue(app.buttons["Hide controls"].waitForExistence(timeout: 5))
        for label in ["Keyboard", "Voice input", "Clipboard", "Fit whole display", "Move view",
                      "Fit", "Fill", "View", "Control", "Controls", "End session"] {
            XCTAssertTrue(app.buttons[label].exists, "Dock is missing \(label)")
        }
        app.buttons["Clipboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.clipboard.row"].firstMatch.waitForExistence(timeout: 3))
        attach("Dock - clipboard row")
        app.buttons["Hide controls"].swipeDown()
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["End session"].exists)
    }

    @MainActor
    func testGestureCoachRunsOnALocalPadAndCanBeSkipped() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach"]
        app.launch()
        let coach = app.descendants(matching: .any)["coach"].firstMatch
        XCTAssertTrue(coach.waitForExistence(timeout: 5))
        let pad = app.descendants(matching: .any)["coach.pad"].firstMatch
        XCTAssertTrue(pad.exists)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))
        attach("Gesture coach - move lesson")
        app.buttons["Skip"].tap()
        XCTAssertTrue(coach.waitForNonExistence(timeout: 5), "Skip closes the lessons")
    }

    @MainActor
    func testFriendlyErrorGivesOneFixAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-error=napping"]
        app.launch()
        let error = app.descendants(matching: .any)["error.napping"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["error.primary"].exists)
        XCTAssertTrue(app.staticTexts["Your Mac is napping."].exists)
        attach("Friendly error - napping")
        app.buttons["Close"].tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home.mac"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPairingSaysWhenACodeHasExpired() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-pairing-paste", "--ui-pairing-expired"]
        app.launch()
        let feedback = app.descendants(matching: .any)["pairing.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label.contains("expired"), "The scanner and paste field say why a code failed")
        XCTAssertTrue(app.buttons["Pair Mac"].exists)
        attach("Pairing - expired code")
    }

    @MainActor
    private func launchOfflineFixture(_ app: XCUIApplication) {
        app.launch()
        let showControls = app.buttons["Show controls"]
        if showControls.waitForExistence(timeout: 3) { return }
        let returnButton = app.buttons["Return to Farside"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must either open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
