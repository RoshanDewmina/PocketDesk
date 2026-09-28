import XCTest

final class SessionLayoutTests: XCTestCase {
    @MainActor
    func testPictureQualityCanSwitchWithoutOpeningKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check"]
        XCUIDevice.shared.orientation = .portrait
        launchOfflineFixture(app)
        app.buttons["Show controls"].tap()
        app.buttons["Controls"].tap()
        let content = app.scrollViews["remote.controls.content"]
        let responsive = app.buttons["Responsive"]
        if !responsive.isHittable { content.swipeUp() }
        XCTAssertTrue(responsive.waitForExistence(timeout: 3))
        responsive.tap()
        XCTAssertTrue(app.staticTexts["Lower resolution for a more responsive connection."].exists)
        app.buttons["Sharper"].tap()
        XCTAssertTrue(app.staticTexts["Sharper text · up to native 4K. Uses more bandwidth."].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attachScreenshot("Picture quality controls - offline layout")
    }

    @MainActor
    func testHomeKeepsPairingAndRecoveryDiscoverable() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let home = app.descendants(matching: .any)["phone.home"].firstMatch
        if !home.waitForExistence(timeout: 3) {
            let recovery = app.buttons["Return to PocketDesk"]
            XCTAssertTrue(recovery.waitForExistence(timeout: 5))
            recovery.tap()
        }
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 3))
        let paste = app.buttons["Paste a pairing code"]
        if !paste.isHittable { app.swipeUp() }
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Pairing code"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Pair Mac"].isEnabled, "Empty pairing input must remain disabled")
        paste.tap()
        XCTAssertTrue(app.buttons["Scan pairing code"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Native phone home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOfflineControlsPortraitLandscapeAndKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check"]
        XCUIDevice.shared.orientation = .portrait
        launchOfflineFixture(app)

        let showControls = app.buttons["Show controls"]
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["remote.canvas"].firstMatch.exists)
        XCTAssertFalse(app.buttons["End session"].exists, "Resting canvas has no permanent header")
        XCTAssertFalse(app.buttons["Release"].exists, "No disabled release control should cover the resting stream")
        attachScreenshot("Default immersive - offline layout")

        showControls.swipeUp()
        let hideControls = app.buttons["Hide controls"]
        XCTAssertTrue(hideControls.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Keyboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["End session"].isHittable)
        let fitWholeDisplay = app.buttons["Fit whole display"]
        XCTAssertTrue(fitWholeDisplay.waitForExistence(timeout: 3), "Fill is the default viewport mode")
        fitWholeDisplay.tap()
        XCTAssertTrue(app.buttons["Fill screen"].waitForExistence(timeout: 3))
        app.buttons["Fill screen"].tap()
        XCTAssertTrue(fitWholeDisplay.waitForExistence(timeout: 3))
        attachScreenshot("Revealed dock - offline layout")

        hideControls.swipeDown()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5), "Downward dock swipe must restore the immersive canvas")
        XCTAssertFalse(app.buttons["End session"].exists)
        showControls.doubleTap()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Handle double tap must open the keyboard directly")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Opening the editor must focus it")
        field.typeText("PocketDesk layout check\nsecond line")
        XCTAssertEqual(field.value as? String, "PocketDesk layout check\nsecond line", "The keyboard panel must retain multiline draft text")
        XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline layout mode must never authorize input")
        attachScreenshot("Focused keyboard portrait - offline layout")

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let landscapeReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height },
            object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [landscapeReady], timeout: 5), .completed, "The app must finish rotating to landscape")
        let hideKeyboard = app.buttons["Hide keyboard"]
        let hideReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: hideKeyboard
        )
        XCTAssertEqual(XCTWaiter().wait(for: [hideReady], timeout: 5), .completed, "Hide keyboard must remain reachable in landscape")
        XCTAssertTrue(app.buttons["End session"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Keyboard commands"].exists, "Landscape must retain modifier and key commands")
        XCTAssertFalse(app.buttons["Release"].exists, "Release only appears while input is held")
        attachScreenshot("Focused keyboard landscape - offline layout")

        hideKeyboard.tap()
        XCTAssertTrue(hideKeyboard.waitForNonExistence(timeout: 5), "Hiding the keyboard must finish its panel transition")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The system keyboard must dismiss before the dock is tapped")
        let landscapeHandle = app.buttons["Hide controls"]
        XCTAssertTrue(landscapeHandle.waitForExistence(timeout: 5))
        landscapeHandle.swipeDown()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5))
        attachScreenshot("Immersive landscape after keyboard dismissal - offline layout")
        app.buttons["Show controls"].swipeUp()
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        XCTAssertTrue(app.buttons["Double-click"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Double-click"].isEnabled, "Offline remote clicks must be disabled")
        XCTAssertTrue(app.buttons["Drag"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Drag"].isEnabled)
        app.buttons["Adjust zoom"].firstMatch.tap()
        let zoom = app.sliders["Zoom level"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Fit whole display"].exists)
        XCTAssertTrue(app.buttons["Fill screen"].exists)
        zoom.adjust(toNormalizedSliderPosition: 0.6)
        let zoomValue = app.staticTexts["Current zoom"]
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 3))
        guard let value = zoomValue.value as? String else {
            return XCTFail("Continuous zoom must expose its current value")
        }
        guard let numericValue = Double(value.replacingOccurrences(of: ",", with: ".")) else {
            return XCTFail("Continuous zoom value must be numeric, got \(value)")
        }
        XCTAssertGreaterThan(numericValue, 2.05, "Slider position 0.6 must move zoom above the 2× preset")
        XCTAssertLessThan(numericValue, 2.35, "Slider position 0.6 must remain between the 2× and 3× presets")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testInactiveSceneConcealsOfflineLayoutUntilExplicitReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check"]
        launchOfflineFixture(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Remote view hidden"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Controls"].exists)
        XCTAssertFalse(app.buttons["Keyboard"].exists)
        XCTAssertFalse(app.buttons["Release"].exists)
        app.buttons["Return to PocketDesk"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func launchOfflineFixture(_ app: XCUIApplication) {
        app.launch()
        let showControls = app.buttons["Show controls"]
        if showControls.waitForExistence(timeout: 2) {
            return
        }

        // A previous scene transition may leave the privacy shield active at process launch.
        let returnButton = app.buttons["Return to PocketDesk"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must either open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5), "Explicit privacy recovery must restore the offline fixture")
    }
}
