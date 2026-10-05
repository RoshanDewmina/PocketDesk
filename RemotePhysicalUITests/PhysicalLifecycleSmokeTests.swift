import XCTest

/// Opt-in hardware checks against the owner's existing pairing and installed host.
/// No fixture, pairing reset, remote clicks/typing, or Mac permission change.
final class PhysicalLifecycleSmokeTests: XCTestCase {
    @MainActor
    private func pairedSession(launchArguments: [String] = []) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1" else {
            throw XCTSkip("Requires explicit physical-device lifecycle testing with a ready paired Mac")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical lifecycle acceptance")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()
        let connect = app.buttons["home.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Preserve the existing pairing")
        connect.tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 20))
        try requireFreshControls(app)
        app.buttons["Done"].firstMatch.tap()
        return app
        #endif
    }

    @MainActor
    private func requireFreshControls(_ app: XCUIApplication) throws {
        let handle = app.buttons["Show controls"].firstMatch
        if handle.exists && handle.isHittable { handle.swipeUp() }
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        controls.tap()
        let click = app.buttons["Double-click"].firstMatch
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: click)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 20), .completed,
                       "Fresh authenticated frames must re-admit controls; do not send a Mac click")
    }

    @MainActor
    func testHomeReturnAutomaticallyRestoresFreshSession() throws {
        let app = try pairedSession()
        try requireHomeReturn(app, backgroundSeconds: 10, label: "default automatic PiP")
    }

    @MainActor
    func testHomeReturnWithoutAutomaticPiPRestoresFreshSession() throws {
        let app = try pairedSession(launchArguments: ["-farsideAutoPiPDisabled", "YES"])
        try requireHomeReturn(app, backgroundSeconds: 50, label: "automatic PiP disabled, 50-second background")
    }

    @MainActor
    private func requireHomeReturn(_ app: XCUIApplication, backgroundSeconds: TimeInterval, label: String) throws {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: backgroundSeconds)
        app.activate()
        // Closing the Controls sheet leaves the session dock expanded. Either chrome
        // state is valid on return; fresh control admission below is the actual gate.
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Show controls"].exists || app.buttons["Hide controls"].exists
        }, object: nil)
        let result = XCTWaiter.wait(for: [restored], timeout: 20)
        record("Physical Home-return " + label + " before readiness assertion", app)
        XCTAssertEqual(result, .completed, "Return must restore the session without tapping Connect")
        XCTAssertFalse(app.buttons["home.connect"].exists)
        try requireFreshControls(app)
        record("Physical Home-return " + label + " fresh controls", app)
    }

    @MainActor
    func testManualPictureInPictureRemainsActiveBeyondStartDeadline() throws {
        let app = try pairedSession()
        try requireFreshControls(app)
        app.buttons["remote.controls.settings"].firstMatch.tap()
        let picture = app.buttons["remote.settings.picture"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        picture.tap()
        let start = app.buttons["Start Picture in Picture"].firstMatch
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled, "Actual stream must offer admitted PiP")
        start.tap()
        let stop = app.buttons["Stop Picture in Picture"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        record("Physical manual PiP active", app)
        Thread.sleep(forTimeInterval: 12)
        record("Physical manual PiP after 12 seconds", app)
        XCTAssertTrue(stop.exists, "Manual PiP must survive the two-second admission deadline")
        stop.tap()
    }

    /// Observation acquisition only. The owner supplies the same continuous Mac scene externally;
    /// screenshots/submission counts do not establish sharper text or smoother actual presentation.
    @MainActor
    func testRendererPacingMatchedSessions() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_RENDER_PACING"] == "1" else {
            throw XCTSkip("Requires explicit renderer A/B capture, a quiet Mac and externally matched moving content")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical renderer performance evidence")
        #else
        let runs = [("A1 baseline", 2), ("B drawable variant", 3), ("A2 repeated baseline", 2)]
        for (label, count) in runs {
            let arguments = ["-PocketDeskStreamStats", "YES",
                             "-farsidePhoneRendererPacingDiagnostics", "YES",
                             "-farsidePhoneRendererDrawableCount", String(count),
                             "-phoneImmediateSourceDrawDisabled", "NO"]
            let app = try pairedSession(launchArguments: arguments)
            let hide = app.buttons["Hide controls"]
            if hide.exists { hide.tap() }
            defer { app.terminate() }
            let started = Date(), startedUptime = ProcessInfo.processInfo.systemUptime
            // No remote click/typing, foreground transition or quality setting during acquisition.
            Thread.sleep(forTimeInterval: 60)
            let ended = Date(), endedUptime = ProcessInfo.processInfo.systemUptime
            record("Renderer pacing " + label + " after 60-second dwell", app)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let boundaries = XCTAttachment(string: """
            Renderer pacing observation: \(label)
            Drawable pool requested: \(count); renderer frame flights remain capped at two.
            Launch arguments: \(arguments.joined(separator: " "))
            Acquisition UTC start: \(format.string(from: started))
            Acquisition UTC end: \(format.string(from: ended))
            Test-runner uptime start: \(startedUptime)
            Test-runner uptime end: \(endedUptime)
            Observation dwell seconds: \(endedUptime - startedUptime)
            Match the same externally controlled Mac content and isolate logs to these windows.
            No performance or sharpness verdict is asserted by this observation test.
            """)
            boundaries.name = "Renderer pacing " + label + " acquisition boundaries"
            boundaries.lifetime = .keepAlways
            add(boundaries)
        }
        #endif
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
