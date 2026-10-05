import XCTest

/// Opt-in hardware checks against the owner's existing pairing and installed host.
/// No fixture, pairing reset, remote clicks/typing, or Mac permission change.
final class PhysicalLifecycleSmokeTests: XCTestCase {
    @MainActor
    private func pairedSession(launchArguments: [String] = [], application: XCUIApplication? = nil) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1" else {
            throw XCTSkip("Requires explicit physical-device lifecycle testing with a ready paired Mac")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical lifecycle acceptance")
        #else
        continueAfterFailure = false
        let app = application ?? XCUIApplication()
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

    /// Exercise real producer retirement and fresh starts without sending remote input.
    /// Fresh enabled Controls is the readiness gate; chrome alone can exist with zero frames.
    @MainActor
    func testRepeatedFreshFirstPictures() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_CAPTURE_START_REPEAT"] == "1" else {
            throw XCTSkip("Requires explicit repeated physical capture-start testing")
        }
        for cycle in 1...5 {
            let app = try pairedSession()
            defer { app.terminate() }
            record("Physical first picture cycle \(cycle) fresh controls", app)
            let end = app.buttons["End session"].firstMatch
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            XCTAssertTrue(end.isHittable)
            end.tap()
            XCTAssertTrue(app.buttons["home.connect"].firstMatch.waitForExistence(timeout: 10),
                          "End must return to the existing paired Home")
        }
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
                             "-PocketDeskMarkerReading", ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_MARKER_CAPTURE"] == "1" ? "YES" : "NO",
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

    /// One acquisition per job. The parent switches the Mac codec externally between jobs;
    /// the same installed phone renderer and externally controlled moving scene serve all codecs.
    @MainActor
    func testSingleCodecComparisonAcquisition() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_PHYSICAL_CODEC_COMPARISON"] == "1",
              environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1" else {
            throw XCTSkip("Requires both explicit physical codec acquisition and lifecycle-testing opt-ins")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator cannot acquire physical codec comparison evidence")
        #else
        let label = environment["FARSIDE_PHYSICAL_CODEC_COMPARISON_LABEL"] ?? "externally selected codec"
        let hostPID = environment["FARSIDE_PHYSICAL_CODEC_HOST_PID"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let arguments = ["-PocketDeskStreamStats", "YES",
                         "-PocketDeskMarkerReading", "YES",
                         "-farsidePhoneRendererPacingDiagnostics", "YES",
                         "-farsidePhoneRendererDrawableCount", "2",
                         "-phoneImmediateSourceDrawDisabled", "NO"]
        let app = XCUIApplication()
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        var boundaries = [
            "Single codec acquisition label: \(label) (external label; not a codec assertion)",
            "Drawable pool requested: 2; frame flights and SmoothMotion remain unchanged.",
            "Launch arguments: \(arguments.joined(separator: " "))",
            "Test-runner PID: \(ProcessInfo.processInfo.processIdentifier)",
            "Host PID supplied externally: \(hostPID.map(String.init) ?? "unavailable")",
            "Phone app PID: unavailable through public XCUIAutomation; correlate external process logs.",
            "Match the same externally controlled Mac scene and verify actual codec/geometry from telemetry.",
            "Only fresh enabled Controls is asserted; no FPS, profile, latency, sharpness or metric verdict."
        ]
        func boundary(_ phase: String) -> TimeInterval {
            let utc = Date(), uptime = ProcessInfo.processInfo.systemUptime
            boundaries.append("\(phase) UTC: \(format.string(from: utc)); test-runner uptime: \(uptime)")
            return uptime
        }
        defer {
            _ = boundary("Cleanup requested")
            app.terminate() // Installed pairing survives; always retire this phone process.
            _ = boundary("Phone app terminated")
            let attachment = XCTAttachment(string: boundaries.joined(separator: "\n"))
            attachment.name = "Codec comparison " + label + " acquisition boundaries"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        _ = boundary("Phone launch requested")
        _ = try pairedSession(launchArguments: arguments, application: app)
        _ = boundary("Fresh Controls admitted")
        let hide = app.buttons["Hide controls"].firstMatch
        if hide.exists { hide.tap() }
        let settlementStart = boundary("Settlement start")
        record("Codec comparison " + label + " settlement start", app)
        Thread.sleep(forTimeInterval: 30)
        let settlementEnd = boundary("Settlement end")
        boundaries.append("Observed settlement seconds: \(settlementEnd - settlementStart)")
        record("Codec comparison " + label + " settlement end", app)
        let dwellStart = boundary("Motion dwell start")
        // No Mac input, quality change, foreground transition or renderer adjustment during dwell.
        Thread.sleep(forTimeInterval: 60)
        let dwellEnd = boundary("Motion dwell end")
        boundaries.append("Observed motion dwell seconds: \(dwellEnd - dwellStart)")
        record("Codec comparison " + label + " motion dwell end", app)
        try requireFreshControls(app)
        _ = boundary("Post-dwell fresh Controls admitted")
        record("Codec comparison " + label + " post-dwell fresh controls", app)
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
