import XCTest

/// A real push, delivered by `xcrun simctl push`, tapped on the real notification banner, must open the
/// alert sheet with the fixed generic copy. A UI test cannot run `simctl`, so `script/push-samples/verify-routing.sh`
/// starts a test, waits for it to write its ready file, pushes the sample, and reads the result.
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

    /// Launches with a paired Mac and alerts on, asks iOS for notification permission the way turning
    /// alerts on does, answers it, and tells the harness to push. The defaults are set on the command line
    /// for this run only, so nothing carries over: a command-line default also beats what the app writes,
    /// which is why the switch is not driven here.
    @MainActor
    private func launchWithAlertsOnAndSignalReady() throws -> XCUIApplication {
        if environment["FARSIDE_PUSH_INJECTED"] == "1" {
            XCUIDevice.shared.orientation = .portrait
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x", "--ui-request-notifications",
                                "-agentAlerts.enabled", "YES", "-agentAlerts.declinedIDs", "()", "-agentAlerts.snoozedIDs", "()"]
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.agentAlerts"].waitForExistence(timeout: 10), "Home is showing")
        // iOS asks once per install; a simulator that already answered goes straight on.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        Thread.sleep(forTimeInterval: 1.0)

        let ready = environment["FARSIDE_PUSH_READY_FILE"] ?? "/tmp/farside-push-ready"
        try "ready".write(toFile: ready, atomically: true, encoding: .utf8)
        return app
    }

    @MainActor
    func testAPushedAlertRoutesToTheRightSheetOrNowhere() throws {
        let tapText = try XCTUnwrap(environment["FARSIDE_PUSH_TAP_TEXT"])
        let expectSheet = environment["FARSIDE_PUSH_EXPECT_SHEET"] == "yes"
        let app = try launchWithAlertsOnAndSignalReady()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.staticTexts[tapText]
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "The pushed notification did not arrive: \(springboard.debugDescription.prefix(300))")
        Thread.sleep(forTimeInterval: 0.8)
        attach("Banner: \(tapText)")
        banner.tap()

        let sheet = app.descendants(matching: .any)["agent.alert.sheet"].firstMatch
        if expectSheet {
            XCTAssertTrue(sheet.waitForExistence(timeout: 15), "Tapping the banner must open the alert sheet")
            let title = try XCTUnwrap(environment["FARSIDE_PUSH_EXPECT_TITLE"])
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "The sheet shows the fixed copy: \(title)")
            attach("Routed sheet: \(title)")
        } else {
            Thread.sleep(forTimeInterval: 4)
            XCTAssertFalse(sheet.exists, "A payload that is not a valid agent alert must not route")
            attach("Nothing routed")
        }
    }

    /// The category the phone registers is what the system shows: Snooze and Not now under the banner,
    /// and choosing one never opens the alert sheet.
    @MainActor
    func testTheBannerOffersSnoozeAndNotNowWithoutOpeningTheAlert() throws {
        let tapText = try XCTUnwrap(environment["FARSIDE_PUSH_TAP_TEXT"])
        let app = try launchWithAlertsOnAndSignalReady()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.staticTexts[tapText]
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "The pushed notification did not arrive")
        banner.press(forDuration: 1.2)

        let snooze = springboard.buttons["Snooze 15 min"]
        let notNow = springboard.buttons["Not now"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 10), "The category offers Snooze 15 min")
        XCTAssertTrue(notNow.exists, "The category offers Not now")
        attach("Actions under the notification")

        notNow.tap()
        Thread.sleep(forTimeInterval: 3)
        let sheet = app.descendants(matching: .any)["agent.alert.sheet"].firstMatch
        XCTAssertFalse(sheet.exists, "An action button is not a tap on the notification")
        XCTAssertFalse(springboard.staticTexts[tapText].exists, "Not now takes the notification away")
        attach("After Not now")
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
