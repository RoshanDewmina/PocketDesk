import XCTest

final class MacVitalsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"] + arguments
        app.launch()
        let returnButton = app.buttons["Return to Farside"]
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        return app
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testControlsCaptionSpeaksTheWholeState() {
        let app = launch(["--ui-controls-check", "--ui-vitals=battery12"])
        let caption = app.staticTexts["remote.controls.vitals"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, "Your Mac: on battery, 12 percent, warm, Low Power Mode, busy.")
        XCTAssertTrue(app.buttons["Hold click"].isHittable, "The caption must not push the keys out of the fixed panel")
        attach("Controls caption · battery 12%")
    }

    @MainActor
    func testCaptionFitsAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-controls-check", "--ui-vitals=battery12",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let returnButton = app.buttons["Return to Farside"]
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let caption = app.staticTexts["remote.controls.vitals"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hold click"].isHittable)
        XCTAssertTrue(app.buttons["remote.controls.settings"].firstMatch.isHittable)
        XCTAssertLessThan(caption.frame.height, 40, "One line, not a wrapped paragraph")
        attach("Controls caption · largest text")
    }

    @MainActor
    func testOlderMacShowsNoCaptionAndExplainsInDiagnostics() {
        let app = launch(["--ui-controls-settings", "--ui-controls-page=diagnostics", "--ui-vitals=old"])
        let section = app.descendants(matching: .any)["remote.vitals"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your Mac’s Farside is too old to report battery and load. Update it on your Mac."].exists)
        XCTAssertFalse(app.staticTexts["remote.controls.vitals"].exists)
    }

    @MainActor
    func testDiagnosticsListsTheMac() {
        let app = launch(["--ui-controls-settings", "--ui-controls-page=diagnostics", "--ui-vitals=battery12"])
        XCTAssertTrue(app.descendants(matching: .any)["remote.vitals"].firstMatch.waitForExistence(timeout: 5))
        for text in ["Battery · 12% · macOS low-battery warning", "Warm", "Busy · processor"] {
            XCTAssertTrue(app.staticTexts[text].exists || app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, text)
        }
        attach("Diagnostics · Mac")
    }

    @MainActor
    func testHomeRemembersALowBattery() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-last-battery=4"]
        app.launch()
        let note = app.staticTexts["home.vitals"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "Last seen on battery · 4%")
        attach("Home · last seen battery")
    }
}
