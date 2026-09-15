import XCTest

final class SessionLayoutTests: XCTestCase {
    @MainActor
    func testOfflineControlsPortraitLandscapeAndKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["Offline layout check. No Mac is connected."].waitForExistence(timeout: 5))
        let keyboard = app.buttons["Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("PocketDesk layout check")
        XCTAssertEqual(field.value as? String, "PocketDesk layout check", "Tapping Keyboard must open a usable text entry control")
        XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline layout mode must never authorize input")
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Portrait keyboard - offline layout"; portrait.lifetime = .keepAlways; add(portrait)
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
        XCTAssertTrue(app.buttons["Session options"].waitForExistence(timeout: 3))
        let landscape = XCTAttachment(screenshot: app.screenshot()); landscape.name = "Landscape keyboard - offline layout"; landscape.lifetime = .keepAlways; add(landscape)
        hideKeyboard.tap()
        XCTAssertTrue(app.buttons["Trackpad"].firstMatch.isHittable)
        app.buttons["Trackpad"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Double-click"].waitForExistence(timeout: 3))
        app.buttons["Double-click"].tap()
        XCTAssertTrue(app.buttons["Drag"].waitForExistence(timeout: 3))
        app.buttons["Drag"].tap()
        XCTAssertFalse(app.buttons["Release"].exists, "Disconnected layout must not start a drag")
        app.buttons["Adjust zoom"].firstMatch.tap()
        let zoom = app.sliders["Zoom level"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
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
        app.launch()
        XCTAssertTrue(app.staticTexts["Offline layout check. No Mac is connected."].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Remote view hidden"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Trackpad"].exists)
        XCTAssertFalse(app.buttons["Keyboard"].exists)
        XCTAssertFalse(app.buttons["Release"].exists)
        app.buttons["Return to PocketDesk"].tap()
        XCTAssertTrue(app.staticTexts["Offline layout check. No Mac is connected."].waitForExistence(timeout: 3))
    }
}
