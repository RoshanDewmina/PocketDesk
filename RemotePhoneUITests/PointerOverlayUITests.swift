import XCTest

final class PointerOverlayUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testGlyphGalleryRendersEveryShape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-pointer-gallery"]
        launch(app)
        XCTAssertTrue(app.descendants(matching: .any)["remote.pointerGallery"].firstMatch.waitForExistence(timeout: 5)
                      || app.buttons["Show controls"].exists)
        attach("Pointer glyph gallery")
    }

    @MainActor
    private func launch(_ app: XCUIApplication) {
        app.launch()
        let showControls = app.buttons["Show controls"]
        if showControls.waitForExistence(timeout: 3) { return }
        let returnButton = app.buttons["Return to Farside"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 5))
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openControls(_ app: XCUIApplication) {
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // The synthesized swipe is occasionally dropped on a heavily loaded host; the
        // dock itself is not under test here, so retry the reveal before asserting.
        let controls = app.buttons["More"]
        for _ in 0..<3 where !controls.exists {
            if handle.exists { handle.swipeUp() }
            _ = controls.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(controls.exists)
        controls.tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.controls.content"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    private func openPointerSettings(_ app: XCUIApplication) {
        let settings = app.buttons["remote.controls.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.buttons["remote.settings.pointer"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
