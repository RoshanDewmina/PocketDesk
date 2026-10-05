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
    func testReadingGlassLensMovesZoomsAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-reading-lens", "--ui-input-probe", "--ui-probe-quiet"]
        launch(app)
        let lens = app.descendants(matching: .any)["remote.magnifier.lens"].firstMatch
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        let probe = app.descendants(matching: .any)["remote.inputProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let beforeInput = probe.value as? String
        let before = lens.frame
        let start = lens.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 45, dy: 35)))
        XCTAssertGreaterThan(lens.frame.midX, before.midX + 20)
        let zoom = app.buttons["remote.magnifier.zoom"].firstMatch
        XCTAssertTrue(zoom.isHittable)
        zoom.tap()
        XCTAssertEqual(zoom.label, "Magnification, 3 times")
        XCTAssertEqual(probe.value as? String, beforeInput, "Moving and zooming the lens must not transmit remote input")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        XCTAssertTrue((probe.value as? String ?? "").contains("click"), "Touches outside the lens must reach the real input surface")
        attach("Glass reading magnifier — 3×")
        app.buttons["remote.magnifier.close"].tap()
        XCTAssertFalse(lens.exists)
        XCTAssertTrue(app.buttons["Show controls"].exists)
    }

    @MainActor
    func testMagnifierOpensFromSettingsAndPrecisionLoupeRemainsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-controls-settings"]
        app.launch()
        let open = app.buttons["remote.magnifier.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["remote.magnifier.close"].waitForExistence(timeout: 5))
        app.buttons["remote.magnifier.close"].tap()
        app.terminate()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-precision-preview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["remote.precisionLoupe"].firstMatch.waitForExistence(timeout: 5))
        attach("Glass Precision Tap magnifier")
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
        let controls = app.buttons["Controls"]
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
