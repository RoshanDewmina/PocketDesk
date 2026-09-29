import XCTest

/// A real push, delivered by `xcrun simctl push`, tapped on the real notification banner, must open the
/// alert sheet for the right agent. A UI test cannot run `simctl`, so `script/push-samples/verify-routing.sh`
/// starts this test, waits for it to write its ready file, pushes the sample, and reads the result.
/// Skipped in ordinary runs.
///
/// Environment (all passed as `TEST_RUNNER_FARSIDE_PUSH_*`):
///   INJECTED      "1" when the harness is driving
///   READY_FILE    written when the app is waiting for the push
///   TAP_TEXT      the text on the banner to tap
///   EXPECT_SHEET  "yes" if a sheet must open, "no" if the payload must not route
///   EXPECT_TITLE  the sheet heading, when a sheet is expected
final class AgentAlertPushUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["FARSIDE_PUSH_INJECTED"] == "1",
                          "Run through script/push-samples/verify-routing.sh, which pushes a sample once this test is ready")
        continueAfterFailure = false
    }

    @MainActor
    func testAPushedAlertRoutesToTheRightSheetOrNowhere() throws {
        let tapText = try XCTUnwrap(environment["FARSIDE_PUSH_TAP_TEXT"])
        let expectSheet = environment["FARSIDE_PUSH_EXPECT_SHEET"] == "yes"

        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x",
                                "-agentAlerts.enabled", "NO", "-agentAlerts.declinedIDs", "()", "-agentAlerts.snoozedIDs", "()"]
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // Turn alerts on, which is the moment iOS is asked. The sim remembers an earlier Allow.
        let row = app.buttons["home.agentAlerts"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let toggle = app.descendants(matching: .any)["agent.settings.alerts"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.tap()
        let test = app.descendants(matching: .any)["agent.settings.test"].firstMatch
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: test)
        waitForExpectations(timeout: 15)
        app.buttons["Done"].tap()

        // Ready: the harness pushes the sample now.
        let ready = environment["FARSIDE_PUSH_READY_FILE"] ?? "/tmp/farside-push-ready"
        try "ready".write(toFile: ready, atomically: true, encoding: .utf8)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.staticTexts[tapText]
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "The pushed notification did not arrive: \(springboard.debugDescription.prefix(300))")
        attach("Banner: \(tapText)")
        banner.tap()

        let sheet = app.descendants(matching: .any)["agent.alert.sheet"].firstMatch
        if expectSheet {
            XCTAssertTrue(sheet.waitForExistence(timeout: 15), "Tapping the banner must open the alert sheet")
            let title = try XCTUnwrap(environment["FARSIDE_PUSH_EXPECT_TITLE"])
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "The sheet names who asked: \(title)")
            attach("Routed sheet: \(title)")
        } else {
            Thread.sleep(forTimeInterval: 4)
            XCTAssertFalse(sheet.exists, "A payload that is not a valid agent alert must not route")
            attach("Nothing routed")
        }
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
