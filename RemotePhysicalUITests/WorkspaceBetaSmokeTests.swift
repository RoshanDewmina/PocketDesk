import XCTest

/// Owner-opted-in UI checks against an existing pairing with the matching, ready Beta Mac.
/// Uses local View gestures only. It sends no Mac clicks/keys and changes no permissions or hidden preferences.
final class WorkspaceBetaSmokeTests: XCTestCase {
    private enum Failure: Error { case unmetRequirement(String) }

    @MainActor
    func testExplicitWorkspaceSmartZoomAndOrdinaryExit() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_WORKSPACE_BETA"] == "1" else {
            throw XCTSkip("Requires explicit physical Workspace beta testing with an already paired, ready matching Beta Mac")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator cannot provide physical Workspace beta evidence")
        #elseif !FARSIDE_WORKSPACE_BETA
        throw XCTSkip("This check runs only in the compiled Workspace beta target")
        #else
        continueAfterFailure = true // Throw after each failed requirement so the cleanup defer runs.
        let app = XCUIApplication()
        defer {
            record("Workspace beta cleanup before End", app)
            bestEffortEnd(app)
            record("Workspace beta cleanup after End", app)
            app.terminate()
        }
        app.launch() // No fixtures, hidden defaults, renderer overrides, pairing resets or permissions.
        record("Workspace beta paired Home", app)
        let connect = app.buttons["home.connect"].firstMatch
        try require(connect.waitForExistence(timeout: 10) && connect.isHittable,
                    "An existing pairing with the ready matching Beta Mac is required")
        connect.tap()
        try require(app.buttons["Show controls"].firstMatch.waitForExistence(timeout: 20), "Session chrome must appear")
        try requireFreshControls(app)
        record("Workspace beta ordinary fresh Controls", app)
        try closeControls(app)
        try require(element("remote.beta.workspace", in: app).waitForExistence(timeout: 5), "The installed phone app must expose beta session chrome")

        try workspaceAction("Try experimental Workspace", in: app)
        record("Workspace beta explicit entry requested", app)
        let ready = app.staticTexts["Workspace ready"].firstMatch
        try require(ready.waitForExistence(timeout: 45),
                    "Workspace ready must follow the model's current geometry, authority and actual original-source presentation gate")
        record("Workspace beta admitted fitted picture", app)
        try requireFreshControls(app)
        let view = element("remote.controls.content", in: app).buttons["Move view"].firstMatch
        try require(view.waitForExistence(timeout: 5) && view.isHittable, "The View selector must be reachable")
        view.tap()
        try require(wait(timeout: 5) { !app.buttons["Done"].firstMatch.isHittable }, "Choosing View must close More")
        let canvas = element("remote.canvas", in: app)
        try require(wait(timeout: 5) { canvas.exists && canvas.label == "Remote desktop view" }, "The native surface must confirm View mode")
        let zoom = app.buttons["Zoom in"].firstMatch
        try require(wait(timeout: 5) { zoom.exists && zoom.isEnabled && zoom.isHittable }, "View Zoom in must be reachable")
        zoom.tap()
        try require(wait(timeout: 5) { app.buttons["Back to view"].firstMatch.isHittable }, "Focus must expose a reachable return")
        settleLocalGesture()
        record("Workspace beta button focus", app)
        app.buttons["Back to view"].firstMatch.tap()
        try require(zoom.waitForExistence(timeout: 5), "Return must remove the focus bookmark UI")
        settleLocalGesture()
        record("Workspace beta button return", app)

        // View closes More and the dock. Confirm the current native View label and derive
        // a fresh picture point below beta chrome and clear of any remaining controls.
        if let point = safeViewPoint(in: app) {
            point.doubleTap()
            try require(wait(timeout: 5) { app.buttons["Back to view"].firstMatch.isHittable }, "A real View double tap must expose return")
            settleLocalGesture()
            record("Workspace beta real View double-tap focus", app)
            // Recompute after focus: keyboard, rotation or system chrome may have moved the surface.
            if let returnPoint = safeViewPoint(in: app) {
                returnPoint.doubleTap()
                try require(zoom.waitForExistence(timeout: 5), "A second View double tap must restore return UI")
            } else {
                recordDoubleTapLimitation("Second double tap not exercised: the current safe View picture area changed after focus. Used reachable Back to view.")
                let back = app.buttons["Back to view"].firstMatch
                try require(back.exists && back.isEnabled && back.isHittable, "A changed canvas must retain a reachable return")
                back.tap()
                try require(zoom.waitForExistence(timeout: 5), "The named return must restore return UI")
            }
            settleLocalGesture()
            record("Workspace beta View gesture return", app)
        } else {
            recordDoubleTapLimitation("Double-tap branch not exercised: no safe hittable picture area with the native surface currently confirming View. Button focus/return was exercised.")
        }

        try workspaceAction("Use normal desktop", in: app)
        record("Workspace beta ordinary exit requested", app)
        try require(wait(timeout: 45) {
            app.staticTexts["Try Workspace"].exists || app.staticTexts["Workspace unavailable on this Mac"].exists
        }, "Exit must finish its ordinary-source restoration gate")
        try requireFreshControls(app)
        record("Workspace beta ordinary source fresh Controls after exit", app)
        try closeControls(app)
        try workspaceAction("End session", in: app)
        try require(connect.waitForExistence(timeout: 10), "End must return to paired Home")
        record("Workspace beta ended on paired Home", app)
        #endif
    }

    @MainActor
    private func safeViewPoint(in app: XCUIApplication) -> XCUICoordinate? {
        let canvas = element("remote.canvas", in: app), picture = element("remote.picture", in: app)
        let zoomBar = element("remote.beta.smartZoom", in: app)
        guard canvas.exists, picture.exists, zoomBar.exists, canvas.isHittable, canvas.isEnabled,
              canvas.label == "Remote desktop view", !app.keyboards.firstMatch.exists,
              !app.buttons["remote.keyboard.hide"].firstMatch.exists,
              !app.textViews["remote.text"].firstMatch.exists,
              !element("remote.privacyShield", in: app).exists,
              !app.buttons["Done"].firstMatch.isHittable else { return nil }
        let bounds = canvas.frame.intersection(picture.frame)
        let top = max(bounds.minY, zoomBar.frame.maxY + 16)
        var bottom = bounds.maxY
        for obstruction in [element("remote.dock", in: app), element("remote.minimap", in: app),
                            app.buttons["Show controls"].firstMatch, app.buttons["Hide controls"].firstMatch] {
            if obstruction.exists && !obstruction.frame.isEmpty { bottom = min(bottom, obstruction.frame.minY - 16) }
        }
        guard !bounds.isNull, bounds.width > 80, bottom - top > 80 else { return nil }
        let offset = CGVector(dx: bounds.midX - canvas.frame.minX, dy: (top + bottom) / 2 - canvas.frame.minY)
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(offset)
    }

    private func recordDoubleTapLimitation(_ text: String) {
        let note = XCTAttachment(string: text + " This run does not establish complete physical double-tap acceptance.")
        note.name = "Workspace beta double-tap coverage limitation"
        note.lifetime = .keepAlways
        add(note)
    }

    @MainActor
    private func requireFreshControls(_ app: XCUIApplication) throws {
        let handle = app.buttons["Show controls"].firstMatch
        if handle.exists && handle.isHittable { handle.swipeUp() }
        let more = app.buttons["More"].firstMatch
        try require(more.waitForExistence(timeout: 10) && more.isHittable, "More must be reachable")
        more.tap()
        // Choosing Control inside More changes only the local input mode. Never tap a Mac action.
        let control = element("remote.controls.content", in: app).buttons["Control desktop"].firstMatch
        try require(control.waitForExistence(timeout: 5) && control.isHittable, "More must expose its local Control selector")
        if !control.isSelected { control.tap() }
        let click = app.buttons["Double-click"].firstMatch
        try require(wait(timeout: 20) { click.exists && click.isEnabled }, "Fresh authenticated frames must enable More actions; never tap a Mac input action")
    }

    @MainActor
    private func closeControls(_ app: XCUIApplication) throws {
        let done = app.buttons["Done"].firstMatch
        try require(done.waitForExistence(timeout: 5) && done.isHittable, "Controls must have a reachable Done action")
        done.tap()
    }

    @MainActor
    private func workspaceAction(_ title: String, in app: XCUIApplication) throws {
        let options = app.buttons["Beta Workspace options"].firstMatch
        try require(options.waitForExistence(timeout: 5) && options.isHittable, "Beta Workspace options must be reachable")
        options.tap()
        let action = app.buttons[title].firstMatch
        try require(action.waitForExistence(timeout: 5) && action.isEnabled && action.isHittable, "Expected enabled beta action: \(title)")
        action.tap()
    }

    @MainActor
    private func bestEffortEnd(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let done = app.buttons["Done"].firstMatch
        if done.exists && done.isHittable { done.tap() }
        let options = app.buttons["Beta Workspace options"].firstMatch
        if options.exists && options.isHittable {
            options.tap()
            let ordinary = app.buttons["Use normal desktop"].firstMatch
            if ordinary.exists && ordinary.isEnabled && ordinary.isHittable {
                ordinary.tap()
                _ = wait(timeout: 10) {
                    app.staticTexts["Try Workspace"].exists || app.staticTexts["Workspace unavailable on this Mac"].exists
                }
                if options.exists && options.isHittable { options.tap() }
            }
        }
        let end = app.buttons["End session"].firstMatch
        if end.exists && end.isHittable {
            end.tap()
            _ = app.buttons["home.connect"].firstMatch.waitForExistence(timeout: 10)
        }
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func wait(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func require(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail(message, file: file, line: line)
            throw Failure.unmetRequirement(message)
        }
    }

    private func settleLocalGesture() {
        Thread.sleep(forTimeInterval: 1) // Sequencing dwell only; no pixels, frame rate or completed presentation is inferred.
    }

    @MainActor
    private func record(_ name: String, _ app: XCUIApplication) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
