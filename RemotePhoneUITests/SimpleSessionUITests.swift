import XCTest

/// Rendered layout and accessibility checks only. The local preview supplies no admitted
/// Workspace source, live camera animation, Mac input, typing or physical performance proof.
/// Existing DEBUG input probe enables local UI controls and records actions without transmission.
final class SimpleSessionUITests: XCTestCase {
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
    func testPortraitBottomKeyboardAndMoreOwnsTouchMode() {
        let app = launchPreview()
        defer { app.terminate() }
        let keyboard = element("remote.keyboard.open", in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.isHittable)
        XCTAssertGreaterThan(keyboard.frame.midY, app.windows.firstMatch.frame.midY, "Manual Keyboard belongs near the bottom")
        record("Simple portrait collapsed manual Keyboard", app)
        openDock(app)
        assertSimpleTiles(app)
        XCTAssertFalse(app.buttons["Move view"].exists, "Touch mode belongs inside More")
        record("Simple portrait expanded Keyboard Files More", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Control desktop"].exists)
        let view = panel.buttons["Move view"].firstMatch
        XCTAssertTrue(view.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "remote.controls.settings").count, 1, "More has one Settings entry")
        record("Simple More owns Control View", app)
        view.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.exists && canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForExistence(timeout: 5), "Choosing View closes the expanded dock")
        XCTAssertTrue(wait { !app.buttons["More"].exists })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        #if FARSIDE_WORKSPACE_BETA
        XCTAssertTrue(app.buttons["Zoom in"].exists, "View exposes named beta focus control; this test does not activate it")
        XCTAssertTrue(element("remote.beta.workspace", in: app).exists)
        XCTAssertFalse(app.staticTexts["Workspace ready"].exists, "An offline preview must not invent Workspace readiness")
        #endif
        record("Simple View closes More and dock", app)
        let control = app.buttons["Control desktop"].firstMatch
        XCTAssertTrue(control.isHittable)
        control.tap()
        XCTAssertTrue(wait { canvas.label != "Remote desktop view" && keyboard.isHittable })
        record("Simple return to Control retains manual Keyboard", app)
    }

    @MainActor
    func testLandscapeExpandedDockUsesWidthAndKeepsMoreReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchPreview()
        defer { app.terminate() }
        openDock(app)
        assertSimpleTiles(app)
        let dock = element("remote.dock", in: app)
        XCTAssertTrue(dock.exists)
        XCTAssertGreaterThan(dock.frame.width, dock.frame.height)
        XCTAssertLessThan(dock.frame.height, app.windows.firstMatch.frame.height * 0.75, "Wide dock must leave room for the picture")
        XCTAssertTrue(app.buttons["End session"].firstMatch.isHittable)
        record("Simple landscape wide dock", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Move view"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["remote.controls.settings"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Done"].firstMatch.isHittable)
        record("Simple landscape More", app)
        panel.buttons["Move view"].firstMatch.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        record("Simple landscape View chrome", app)
    }

    @MainActor
    func testLargeTextMoreAndSettingsRemainReachableWithoutDictate() {
        let app = launchPreview(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { app.terminate() }
        openDock(app)
        assertSimpleTiles(app)
        record("Simple large text expanded dock", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Move view"].firstMatch.isHittable)
        let settings = app.buttons["remote.controls.settings"].firstMatch
        XCTAssertTrue(settings.isHittable)
        record("Simple large text More", app)
        panel.buttons["Move view"].firstMatch.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        record("Simple large text View chrome", app)
        app.buttons["Control desktop"].firstMatch.tap()
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].firstMatch.isHittable)
        record("Simple large text session Settings", app)
    }

    @MainActor
    func testManualKeyboardOpensDockWithoutDedicatedDictateTile() {
        let app = launchPreview(extra: ["--ui-software-keyboard"])
        defer { app.terminate() }
        let keyboard = element("remote.keyboard.open", in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5) && keyboard.isHittable)
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let draft = app.textViews["remote.text"].firstMatch
        XCTAssertTrue(draft.isHittable, "Manual Keyboard opens the real draft field")
        XCTAssertTrue(app.buttons["remote.keyboard.hide"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        XCTAssertFalse(app.buttons["Move view"].exists)
        record("Simple manual keyboard dock no dedicated Dictate", app)
        // The native system keyboard may expose its own mic. No typing/dictation is sent.
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists && keyboard.isHittable })
    }

    @MainActor
    private func launchPreview(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-input-probe", "--ui-probe-quiet",
                               "-FarsideBottomControls", "YES",
                               "-FarsideAutoKeyboard", "NO"] + extra
        app.launch()
        let handle = app.buttons["Show controls"].firstMatch
        if !handle.waitForExistence(timeout: 3) {
            let recover = app.buttons["Return to Farside"].firstMatch
            XCTAssertTrue(recover.waitForExistence(timeout: 5))
            recover.tap()
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
        }
        return app
    }

    @MainActor
    private func openDock(_ app: XCUIApplication) {
        app.buttons["Show controls"].firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertSimpleTiles(_ app: XCUIApplication) {
        for title in ["Keyboard", "More"] { XCTAssertTrue(app.buttons[title].firstMatch.isHittable, title) }
        XCTAssertTrue(app.buttons["Files"].exists || app.buttons["Clipboard"].exists)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        XCTAssertFalse(app.buttons["Dictate"].exists)
        XCTAssertFalse(app.buttons["Controls"].exists)
    }

    @MainActor
    private func assertBetaViewChrome(_ app: XCUIApplication) {
        #if FARSIDE_WORKSPACE_BETA
        let bar = element("remote.beta.smartZoom", in: app)
        let workspace = element("remote.beta.workspace", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5) && workspace.exists)
        for title in ["Zoom in", "Fit", "Look around", "Control desktop"] {
            XCTAssertTrue(bar.buttons[title].firstMatch.isHittable, title)
        }
        XCTAssertFalse(app.staticTexts["View · drag or pinch"].exists, "View status and Control escape share the zoom chrome")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Control desktop")).count, 1)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(bar.frame), "View chrome must fit the visible window")
        XCTAssertGreaterThanOrEqual(bar.frame.minY, workspace.frame.maxY, "Zoom chrome must not cover Workspace status")
        #endif
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func record(_ title: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = title + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
