import XCTest

final class SessionLayoutTests: XCTestCase {
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
    func testPictureQualityCanSwitchWithoutOpeningKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        revealDock(app)
        app.buttons["Controls"].tap()
        let responsive = app.buttons["Responsive"]
        let controlsContent = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        XCTAssertTrue(controlsContent.waitForExistence(timeout: 3))
        for _ in 0..<5 {
            if responsive.exists && responsive.isHittable { break }
            controlsContent.swipeUp()
        }
        XCTAssertTrue(responsive.exists && responsive.isHittable,
                      "Picture quality must remain reachable below the gesture and workspace controls")
        responsive.tap()
        XCTAssertTrue(app.staticTexts["Lower resolution for a more responsive connection."].exists)
        app.buttons["Sharper"].tap()
        XCTAssertTrue(app.staticTexts["Sharper text and detail. Uses more bandwidth."].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attachScreenshot("Picture quality controls - offline layout")
    }

    @MainActor
    func testHomeKeepsPairingAndRecoveryDiscoverable() throws {
        let app = XCUIApplication()
        app.launch()
        let home = app.descendants(matching: .any)["phone.home"].firstMatch
        if !home.waitForExistence(timeout: 3) {
            let recovery = app.buttons["Return to PocketDesk"]
            XCTAssertTrue(recovery.waitForExistence(timeout: 5))
            recovery.tap()
        }
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let paste = app.buttons["Paste a pairing code"]
        guard paste.waitForExistence(timeout: 3) else {
            throw XCTSkip("A Mac is already paired in this simulator; the empty home state is not shown")
        }
        XCTAssertTrue(app.buttons["Scan pairing code"].exists)
        paste.tap()
        let field = app.descendants(matching: .any)["Pairing code"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let pair = app.buttons["Pair Mac"]
        XCTAssertTrue(pair.waitForExistence(timeout: 3))
        XCTAssertFalse(pair.isEnabled, "Empty pairing input must remain disabled")
        XCTAssertTrue(pair.isHittable, "The confirm button must stay on screen")
        attachScreenshot("Pairing sheet - paste")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Scan pairing code"].isHittable)
        attachScreenshot("Native phone home")
    }

    @MainActor
    func testOfflineControlsPortraitLandscapeAndKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
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
        XCTAssertEqual(field.value as? String, "PocketDesk layout check\nsecond line", "The keyboard bar must retain multiline draft text")
        XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline layout mode must never authorize input")
        XCTAssertTrue(app.buttons["Escape"].exists, "Keyboard bar offers Escape, Tab, modifiers and arrows")
        XCTAssertTrue(app.buttons["Command"].exists)
        attachScreenshot("Focused keyboard portrait - offline layout")

        rotate(app, to: .landscapeLeft)
        let hideKeyboard = app.buttons["Hide keyboard"]
        let hideReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: hideKeyboard)
        XCTAssertEqual(XCTWaiter().wait(for: [hideReady], timeout: 5), .completed, "Hide keyboard must remain reachable in landscape")
        XCTAssertTrue(app.buttons["Escape"].exists, "Landscape must retain key commands")
        XCTAssertFalse(app.buttons["Release"].exists, "Release only appears while input is held")
        attachScreenshot("Focused keyboard landscape - offline layout")

        hideKeyboard.tap()
        XCTAssertTrue(hideKeyboard.waitForNonExistence(timeout: 5), "Hiding the keyboard must remove its bar")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The system keyboard must dismiss before the dock is used")
        let landscapeHandle = app.buttons["Show controls"]
        XCTAssertTrue(landscapeHandle.waitForExistence(timeout: 5))
        attachScreenshot("Immersive landscape after keyboard dismissal - offline layout")
        landscapeHandle.swipeUp()
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        XCTAssertTrue(app.buttons["Double-click"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Double-click"].isEnabled, "Offline remote clicks must be disabled")
        XCTAssertTrue(app.buttons["Drag"].exists)
        XCTAssertFalse(app.buttons["Drag"].isEnabled)
        let zoom = app.sliders["Zoom level"]
        let controlsContent = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        XCTAssertTrue(controlsContent.waitForExistence(timeout: 3))
        for _ in 0..<3 {
            if zoom.exists && zoom.isHittable { break }
            controlsContent.swipeUp()
        }
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        zoom.adjust(toNormalizedSliderPosition: 0.8)
        let zoomValue = app.staticTexts["Current zoom"]
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 3))
        guard let value = zoomValue.value as? String,
              let numeric = Double(value.replacingOccurrences(of: ",", with: ".")) else {
            return XCTFail("Continuous zoom must expose a numeric value")
        }
        XCTAssertGreaterThan(numeric, 1.5, "Slider position 0.8 must zoom in beyond the Fill size")
        XCTAssertLessThanOrEqual(numeric, 3.0001)
    }

    @MainActor
    func testViewportModeIsRememberedAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        revealDock(app)
        app.buttons["Fit whole display"].tap()
        XCTAssertTrue(app.buttons["Fill screen"].waitForExistence(timeout: 3))
        app.terminate()

        app.launchArguments = ["--ui-layout-check"]
        launchOfflineFixture(app)
        revealDock(app)
        XCTAssertTrue(app.buttons["Fill screen"].waitForExistence(timeout: 3), "Fit must be remembered after relaunch")
        app.buttons["Fill screen"].tap()
        XCTAssertTrue(app.buttons["Fit whole display"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLandscapeControlsKeepZoomReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        rotate(app, to: .landscapeLeft)

        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.tap()
        let controls = app.buttons["Controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()

        let content = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        let zoom = app.sliders["Zoom level"]
        for _ in 0..<3 {
            if zoom.exists && zoom.isHittable { break }
            content.swipeUp()
        }
        XCTAssertTrue(zoom.exists && zoom.isHittable, "Zoom must stay reachable in a landscape Controls sheet")
        zoom.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertTrue(app.staticTexts["Current zoom"].exists)
        attachScreenshot("Landscape controls - reachable zoom")
    }

    @MainActor
    func testViewModeDoubleTapZoomAndReturnToControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit"]
        launchOfflineFixture(app)
        revealDock(app)

        let moveView = app.buttons["Move view"]
        XCTAssertTrue(moveView.waitForExistence(timeout: 3))
        moveView.tap()
        let canvas = app.descendants(matching: .any)["remote.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertEqual(canvas.label, "Remote desktop view")
        canvas.doubleTap()
        attachScreenshot("View mode zoomed - offline layout")
        app.buttons["Controls"].tap()
        let zoomValue = app.staticTexts["Current zoom"]
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 3))
        guard let value = zoomValue.value as? String,
              let numeric = Double(value.replacingOccurrences(of: ",", with: ".")) else {
            return XCTFail("Double-tap zoom must expose a numeric value")
        }
        XCTAssertGreaterThan(numeric, 1, "View double-tap must zoom into the desktop")
        app.buttons["Done"].tap()
        app.buttons["Control desktop"].firstMatch.tap()
        XCTAssertEqual(canvas.label, "Remote desktop trackpad")
        attachScreenshot("View mode zoom and control toggle")
    }

    @MainActor
    func testKeyboardKeepsDeliberatelyTypedMultilineDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.doubleTap()

        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let expected = "PocketDesk layout check\nsecond line"
        for character in expected {
            field.typeText(String(character))
            Thread.sleep(forTimeInterval: 0.08)
        }
        XCTAssertEqual(field.value as? String, expected)
        XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline preview cannot authorize input")
        attachScreenshot("Focused keyboard with multiline draft")
    }

    @MainActor
    func testBackgroundConcealsOfflineLayoutUntilExplicitReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check"]
        launchOfflineFixture(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Session ended"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Controls"].exists)
        XCTAssertFalse(app.buttons["Keyboard"].exists)
        XCTAssertFalse(app.buttons["Release"].exists)
        app.buttons["Return to PocketDesk"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func revealDock(_ app: XCUIApplication) {
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.swipeUp()
        XCTAssertTrue(app.buttons["Hide controls"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let window = app.windows.firstMatch
        let landscape = orientation.isLandscape
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (window.frame.width > window.frame.height) == landscape
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 5), .completed, "The app must finish rotating")
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
        if showControls.waitForExistence(timeout: 3) { return }
        let returnButton = app.buttons["Return to PocketDesk"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must either open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5), "Explicit privacy recovery must restore the offline fixture")
    }
}
