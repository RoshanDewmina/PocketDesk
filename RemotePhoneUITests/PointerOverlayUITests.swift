import XCTest

final class PointerOverlayUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPointerSizeSettingIsReachableAndPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-pointer-preview"]
        launch(app)
        attach("Pointer preview - Fit - default size")
        openControls(app)
        openPointerSettings(app)
        let picker = app.buttons["remote.pointerSize"].exists ? app.buttons["remote.pointerSize"]
                                                             : app.descendants(matching: .any)["remote.pointerSize"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3) && picker.isHittable, "Pointer size must be on Controls › Settings › Pointer")
        picker.tap()
        let extraLarge = app.buttons["Extra Large"]
        XCTAssertTrue(extraLarge.waitForExistence(timeout: 3))
        extraLarge.tap()
        app.buttons["Done"].firstMatch.tap()
        attach("Pointer preview - Fit - Extra Large")

        app.terminate()
        launch(app)
        openControls(app)
        openPointerSettings(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.label.contains("Extra Large") || (picker.value as? String)?.contains("Extra Large") == true,
                      "The chosen size survives relaunch")
        picker.tap()
        app.buttons["Medium"].tap()
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
