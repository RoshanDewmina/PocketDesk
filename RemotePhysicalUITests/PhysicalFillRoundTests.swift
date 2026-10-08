import XCTest

/// Holds a Fill-view session for a Fill A/B round (claude/fill-view, 7 Oct 2026): switches the phone to
/// View mode, pans across the display, pinches in and out and rests between gestures, so the Mac's
/// crop rect, output size, region switches and key frames can be compared across host flags.
/// Phone-side only: View mode sends no input, and every gesture is preceded by a check that View mode is
/// still on (`panMode` is view state and resets if the session view is recreated); the round stops otherwise.
final class PhysicalFillRoundTests: XCTestCase {
    private struct ViewModeLost: Error {}

    @MainActor
    func testFillRound() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_PHYSICAL_AB_FILL"] == "1" else {
            throw XCTSkip("Requires an explicit Fill round with a ready paired Mac")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not a physical Fill round")
        #else
        continueAfterFailure = false
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let pans = Int(environment["FARSIDE_AB_PANS"] ?? "") ?? 8
        let pinches = Int(environment["FARSIDE_AB_PINCHES"] ?? "") ?? 4
        let rest = TimeInterval(environment["FARSIDE_AB_REST"] ?? "") ?? 1.5
        let landscape = environment["FARSIDE_AB_LANDSCAPE"] == "1"
        let app = XCUIApplication()
        app.launchArguments = ["-viewportMode", "fill"]
            + (environment["FARSIDE_AB_ARGS"] ?? "").split(separator: " ").map(String.init)
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app.launch()
        let connect = app.buttons["home.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "Preserve the existing pairing")
        connect.tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 30), "Session must start")
        Thread.sleep(forTimeInterval: 5)
        try enterViewMode(app)
        Thread.sleep(forTimeInterval: rest)

        let canvas = app.otherElements["remote.canvas"].firstMatch
        let frame = canvas.exists ? canvas.frame : app.windows.firstMatch.frame
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        // Portrait Fill shows the display's full height, so pans are horizontal; landscape the reverse.
        for index in 0..<pans {
            try requireViewMode(app)
            let sign: CGFloat = index % 2 == 0 ? -1 : 1
            let travel = (landscape ? frame.height : frame.width) * 0.6 * sign
            let from = point(frame.midX - (landscape ? 0 : travel / 2), frame.midY - (landscape ? travel / 2 : 0))
            let to = point(frame.midX + (landscape ? 0 : travel / 2), frame.midY + (landscape ? travel / 2 : 0))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: rest)
        }
        for index in 0..<pinches {
            try requireViewMode(app)
            let out = index % 2 == 0
            (canvas.exists ? canvas : window).pinch(withScale: out ? 1.6 : 0.625, velocity: out ? 1 : -1)
            Thread.sleep(forTimeInterval: rest)
        }
        XCTAssertFalse(app.buttons["home.connect"].exists, "Session must survive the round")
        app.terminate()
        #endif
    }

    /// Show controls → More → "Move view" (the View segment's spoken title), then the proof: the pill's
    /// "Control desktop" return button is on screen. Without it a one-finger drag would move the Mac's pointer.
    @MainActor
    private func enterViewMode(_ app: XCUIApplication) throws {
        let handle = app.buttons["Show controls"].firstMatch
        if handle.exists && handle.isHittable { handle.tap() }
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 5) && more.isHittable { more.tap() }
        let option = app.buttons["Move view"].firstMatch
        guard option.waitForExistence(timeout: 5), option.isHittable else {
            XCTFail("View mode option not found; a pan in Control mode would move the Mac's pointer")
            throw ViewModeLost()
        }
        option.tap()
        Thread.sleep(forTimeInterval: 1)
        guard viewModeIsOn(app) else {
            XCTFail("View mode did not take; a pan in Control mode would move the Mac's pointer")
            throw ViewModeLost()
        }
    }

    /// With the segments on screen, the "Move view" segment carries the selected trait in View mode; with
    /// the dock collapsed, the only "Control desktop" button left is the View pill's unselected return
    /// button (the Control segment carries that label too, selected, in Control mode).
    @MainActor
    private func viewModeIsOn(_ app: XCUIApplication) -> Bool {
        let segment = app.buttons["Move view"].firstMatch
        if segment.exists { return segment.isSelected }
        let control = app.buttons["Control desktop"].firstMatch
        return control.exists && !control.isSelected
    }

    @MainActor
    private func requireViewMode(_ app: XCUIApplication) throws {
        guard viewModeIsOn(app) else {
            XCTFail("View mode was lost; stopping before a gesture could reach the Mac")
            throw ViewModeLost()
        }
    }
}
