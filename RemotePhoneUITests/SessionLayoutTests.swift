import XCTest
import UIKit

final class SessionLayoutTests: XCTestCase {
    @MainActor
    func testRegularInputSettingsHaveNoPencilOptIn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-controls-settings", "--ui-controls-page=keyboard"]
        app.launch()
        XCTAssertTrue(app.buttons["remote.mouse.lock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["remote.pencil.enabled"].exists)
        XCTAssertTrue(app.switches["remote.hardware.remap"].exists)
        attachScreenshot("Pencil always available with explicit mouse lock and shortcut remap")
    }
    @MainActor
    func testRegularPortraitPictureStacksOverPadAndSurvivesKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-software-keyboard"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["remote.session.pill"].firstMatch.waitForExistence(timeout: 5),
                      "Regular iPad must expose the pill")
        let picture = app.descendants(matching: .any)["remote.picture"].firstMatch
        let pad = app.descendants(matching: .any)["remote.stacked.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        XCTAssertTrue(picture.exists)
        XCTAssertEqual(picture.frame.height, picture.frame.width / 1.6, accuracy: 2)
        XCTAssertLessThanOrEqual(picture.frame.maxY, pad.frame.minY + 14)
        let before = picture.frame
        app.buttons["Show controls"].doubleTap()
        XCTAssertTrue(app.buttons["remote.keyboard.hide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(picture.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(picture.frame.height, before.height, accuracy: 1)
        attachScreenshot("iPad stack with soft keyboard in pad")
        app.buttons["remote.keyboard.hide"].tap()
        rotate(app, to: .landscapeLeft)
        XCTAssertTrue(pad.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(picture.frame.width, picture.frame.height)
        attachScreenshot("iPad rotated full-bleed picture")
    }

    @MainActor
    func testRegular690PointBandStacksAndCompactBandKeepsHandle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-window-width=690", "--ui-window-height=1032"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["remote.session.pill"].firstMatch.waitForExistence(timeout: 5))
        let picture = app.descendants(matching: .any)["remote.picture"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["remote.stacked.pad"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(picture.frame.width, 690, accuracy: 2)
        XCTAssertEqual(picture.frame.height, 690 / 1.6, accuracy: 2)
        app.terminate()
        app.launchArguments = ["--ui-layout-check", "--ui-window-width=390", "--ui-window-height=834", "--ui-width-class=compact"]
        app.launch()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["remote.session.pill"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["remote.stacked.pad"].firstMatch.exists)
        attachScreenshot("Compact iPad band retains phone chrome")
    }
    /// Opt-in only: uses the owner's existing pairing without typing or clicking on the Mac.
    /// Simulator fixture tests cannot catch the physical-device Swift metadata stack limit.
    @MainActor
    func testPairedDeviceConnectSurvivesSessionConstruction() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PAIRED_DEVICE_SMOKE"] == "1" else {
            throw XCTSkip("Requires an explicitly available paired physical phone and Mac")
        }
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<2 {
            let connect = app.buttons["home.connect"]
            XCTAssertTrue(connect.waitForExistence(timeout: 10), "Use an existing pairing; do not create or reset one")
            connect.tap()
            let handle = app.buttons["Show controls"]
            XCTAssertTrue(handle.waitForExistence(timeout: 20), "Connect must construct the session on hardware")
            XCTAssertEqual(app.state, .runningForeground)
            handle.swipeUp()
            let controls = app.buttons["Controls"].firstMatch
            XCTAssertTrue(controls.waitForExistence(timeout: 10))
            controls.tap()
            let click = app.buttons["Double-click"].firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: click)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                           "The real stream must become fresh and admit controls; no Mac click is sent")
            app.buttons["remote.controls.settings"].firstMatch.tap()
            XCTAssertTrue(app.buttons["remote.settings.picture"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["Done"].firstMatch.tap()
            let end = app.buttons["End session"].firstMatch
            if !end.exists { app.buttons["Show controls"].swipeUp() }
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            end.tap()
            XCTAssertTrue(connect.waitForExistence(timeout: 10), "End must return to the same saved pairing")
        }
    }

    @MainActor
    func testEditableFocusPreviewOpensExistingKeyboardWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-auto-keyboard-preview-check"]
        app.launch()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Editable-focus event should reveal the existing text editor")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline preview never admits Mac input")
        attachScreenshot("Editable focus opens local keyboard - offline preview")
        app.buttons["Hide keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "Manual dismissal must remain effective")
    }

    @MainActor
    func testLongVoicePreviewKeepsDoneReachableInLandscapeWithoutRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-voice-preview-check"]
        app.launch()
        let transcript = app.descendants(matching: .any)["remote.voice.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let done = app.buttons["remote.voice.done"]
        XCTAssertTrue(done.exists && done.isHittable)
        XCTAssertFalse(done.isEnabled, "Offline preview cannot insert text on a Mac")
        attachScreenshot("Voice input long transcript - portrait preview")
        rotate(app, to: .landscapeLeft)
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable, "The anchored Done action stays reachable below long speech")
        attachScreenshot("Voice input long transcript - landscape preview")
    }

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
    func testDataWarningLeavesEndSessionAndControlsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-data-warning"]
        launchOfflineFixture(app)
        let card = app.descendants(matching: .any)["remote.dataWarning"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The forced cellular notice must show over the session")
        revealDock(app)
        let end = app.buttons["End session"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        XCTAssertTrue(end.isHittable, "The notice must not cover End session")
        XCTAssertTrue(app.buttons["Controls"].firstMatch.isHittable)
        XCTAssertFalse(card.frame.intersects(end.frame))
        XCTAssertFalse(app.buttons["remote.dataWarning.less"].exists, "No preset change before the Mac applies one")
        attachScreenshot("Cellular data notice over the session dock")
        app.buttons["remote.dataWarning.keep"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testAccessibilityXXXLDataNoticeWithBannerLeavesDockReachable() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-data-warning",
                                   "--ui-data-warning-lower", "--ui-reconnect-back",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            launchOfflineFixture(app)
            revealDock(app)
            let card = app.descendants(matching: .any)["remote.dataWarning"].firstMatch
            let end = app.buttons["End session"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertTrue(end.isHittable && app.buttons["Controls"].firstMatch.isHittable)
            XCTAssertFalse(card.frame.intersects(end.frame), "Notice below another banner must stop above End")
            for id in ["remote.dataWarning.less", "remote.dataWarning.keep"] {
                let button = app.buttons[id]
                let scroll = card.elementType == .scrollView ? card : card.scrollViews.firstMatch
                for _ in 0..<6 where !button.isHittable { scroll.swipeUp() }
                XCTAssertTrue(button.isHittable, "Both notice actions must be reachable in \(orientation)")
            }
            attachScreenshot("AX-XXXL data warning with banner \(orientation)")
            app.buttons["remote.dataWarning.less"].tap()
            XCTAssertTrue(card.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testPictureQualityCanSwitchWithoutOpeningKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        revealDock(app)
        app.buttons["Controls"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.controls.content"].firstMatch.waitForExistence(timeout: 3))
        openSettingsPage(app, "picture")
        let responsive = app.buttons["Responsive"]
        XCTAssertTrue(responsive.waitForExistence(timeout: 3) && responsive.isHittable,
                      "Picture quality must be one page away in Controls › Settings")
        responsive.tap()
        XCTAssertTrue(app.staticTexts["Lower resolution for a more responsive connection."].exists)
        app.buttons["Sharper"].tap()
        XCTAssertTrue(app.staticTexts["Sharper text and detail. Uses more bandwidth."].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attachScreenshot("Picture quality controls - offline layout")
    }

    @MainActor
    func testOpeningSettingsDropsExplicitHoldBeforeDropIsHidden() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-controls-check",
                               "--ui-hold-preview=explicit"]
        launchOfflineFixture(app)
        XCTAssertTrue(app.descendants(matching: .any)["remote.holdChip"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Drop"].firstMatch.exists)

        app.buttons["remote.controls.settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["remote.settings.picture"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.holdChip"].firstMatch.waitForNonExistence(timeout: 3),
                      "A hidden Drop control must never leave the Mac mouse button held")
    }

    @MainActor
    func testHomeKeepsPairingAndRecoveryDiscoverable() throws {
        let app = XCUIApplication()
        app.launch()
        let home = app.descendants(matching: .any)["phone.home"].firstMatch
        if !home.waitForExistence(timeout: 3) {
            let recovery = app.buttons["Return to Farside"]
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
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-software-keyboard"]
        launchOfflineFixture(app)

        let showControls = app.buttons["Show controls"]
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["remote.canvas"].firstMatch.exists)
        XCTAssertFalse(app.buttons["End session"].exists, "Resting canvas has no permanent header")
        XCTAssertFalse(app.buttons["Release"].exists, "No disabled release control should cover the resting stream")
        attachScreenshot("Default immersive - offline layout")

        if app.descendants(matching: .any)["remote.session.pill"].firstMatch.exists { showControls.tap() }
        else { showControls.swipeUp() }
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

        if app.descendants(matching: .any)["remote.session.pill"].firstMatch.exists { hideControls.tap() }
        else { hideControls.swipeDown() }
        XCTAssertTrue(showControls.waitForExistence(timeout: 5), "Downward dock swipe must restore the immersive canvas")
        XCTAssertFalse(app.buttons["End session"].exists)
        showControls.doubleTap()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Handle double tap must open the keyboard directly")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Opening the editor must focus it")
        field.typeText("Farside layout check\nsecond line")
        XCTAssertEqual(field.value as? String, "Farside layout check\nsecond line", "The keyboard bar must retain multiline draft text")
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
        if app.descendants(matching: .any)["remote.session.pill"].firstMatch.exists { landscapeHandle.tap() }
        else { landscapeHandle.swipeUp() }
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        XCTAssertTrue(app.buttons["Double-click"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Double-click"].isEnabled, "Offline remote clicks must be disabled")
        XCTAssertTrue(app.buttons["Hold click"].exists)
        XCTAssertFalse(app.buttons["Hold click"].isEnabled)
        XCTAssertTrue(app.buttons["Mission Control"].isHittable, "Landscape keys fit in one row without scrolling")
        attachScreenshot("Controls keys landscape - offline layout")
        openSettingsPage(app, "view")
        let zoom = app.sliders["Zoom level"]
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
        openSettingsPage(app, "view")
        let zoom = app.sliders["Zoom level"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 3) && zoom.isHittable, "Zoom must stay reachable from landscape Controls")
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
        openSettingsPage(app, "view")
        let zoomValue = app.staticTexts["Current zoom"]
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 3))
        guard let value = zoomValue.value as? String,
              let numeric = Double(value.replacingOccurrences(of: ",", with: ".")) else {
            return XCTFail("Double-tap zoom must expose a numeric value")
        }
        XCTAssertGreaterThan(numeric, 1, "View double-tap must zoom into the desktop")
        app.buttons["Done"].firstMatch.tap()
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
        let expected = "Farside layout check\nsecond line"
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
        app.buttons["Return to Farside"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testRegularSessionPillDockAndKeysShareTopAnchor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-demo-mac"]
        launchOfflineFixture(app)
        try requireRegularPill(app)
        let pill = app.descendants(matching: .any)["remote.session.pill"].firstMatch
        let canvas = app.descendants(matching: .any)["remote.canvas"].firstMatch
        XCTAssertGreaterThanOrEqual(pill.frame.minY, canvas.frame.minY)
        XCTAssertLessThan(pill.frame.minY - canvas.frame.minY, 60)
        app.buttons["Show controls"].tap()
        let dock = app.descendants(matching: .any)["remote.dock"].firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(dock.frame.minY, pill.frame.maxY)
        XCTAssertLessThanOrEqual(dock.frame.width, 560.5)
        app.buttons["Controls"].firstMatch.tap()
        let keys = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(keys.frame.minY, pill.frame.maxY)
        XCTAssertLessThan(keys.frame.maxY, app.windows.firstMatch.frame.maxY - 120)
        attachScreenshot("Regular session top pill dock and keys")
    }

    @MainActor
    func testRegularPersistentStatesStayInsidePillAfterIdle() throws {
        for (argument, identifier) in [("--ui-reconnecting", "remote.reconnecting"),
                                       ("--ui-reconnect-back", "remote.back"),
                                       ("--ui-mac-busy", "remote.macBusy"),
                                       ("--ui-big-text-changing", "remote.bigText.pill")] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", argument]
            launchOfflineFixture(app)
            try requireRegularPill(app)
            let pill = app.descendants(matching: .any)["remote.session.pill"].firstMatch
            let state = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 3))
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Expanded'"), object: pill)
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 3), .completed)
            // Check after the two-second connected-presentation timeout, without touching the stage.
            Thread.sleep(forTimeInterval: 2.2)
            XCTAssertEqual(pill.value as? String, "Expanded")
            XCTAssertTrue(pill.frame.insetBy(dx: -1, dy: -1).contains(state.frame))
            if argument == "--ui-reconnecting" { XCTAssertTrue(app.buttons["End session"].isHittable) }
            app.terminate()
        }
    }

    @MainActor
    func testRegularConnectedPillCollapsesAndDoubleTapOpensKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-software-keyboard", "--ui-input-probe"]
        launchOfflineFixture(app)
        try requireRegularPill(app)
        let pill = app.descendants(matching: .any)["remote.session.pill"].firstMatch
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Collapsed'"), object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 5), .completed)
        app.buttons["Show controls"].doubleTap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Command"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let returnKey = app.buttons.matching(NSPredicate(format: "identifier == 'remote.keys' AND label == 'Return'")).firstMatch
        XCTAssertTrue(returnKey.isEnabled)
        XCTAssertTrue(returnKey.isHittable, "The regular keyboard row must expose its final key without scrolling")
        XCTAssertFalse(app.descendants(matching: .any)["remote.keys"].firstMatch.scrollViews.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["remote.dock"].firstMatch.exists)
    }

    @MainActor
    func testRegularHardwareKeyboardShowsTextFieldWithoutKeyBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-hardware-keyboard"]
        launchOfflineFixture(app)
        try requireRegularPill(app)
        app.buttons["Show controls"].doubleTap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["remote.keys"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Command"].exists)
        XCTAssertTrue(app.buttons["remote.keyboard.hide"].isHittable)
        XCTAssertFalse(app.buttons["Send text"].isEnabled)
    }

    @MainActor
    private func requireRegularPill(_ app: XCUIApplication) throws {
        guard app.windows.firstMatch.frame.width >= 680 else {
            throw XCTSkip("Regular-width iPad simulator check")
        }
        XCTAssertTrue(app.descendants(matching: .any)["remote.session.pill"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Controls › Settings › one page, by the summary row's identifier (picture, view, …).
    @MainActor
    private func openSettingsPage(_ app: XCUIApplication, _ page: String) {
        let settings = app.buttons["remote.controls.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.buttons["remote.settings.\(page)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    @MainActor
    private func revealDock(_ app: XCUIApplication) {
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        if app.descendants(matching: .any)["remote.session.pill"].firstMatch.exists { handle.tap() }
        else { handle.swipeUp() }
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
        let returnButton = app.buttons["Return to Farside"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must either open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5), "Explicit privacy recovery must restore the offline fixture")
    }
}
