import XCTest

/// Alerts, the Lock Screen settings and notification routing, exercised in the app the way a person uses
/// it. Launch arguments starting with `-` override UserDefaults for the run only, so no test leaves a
/// choice behind for the next.
final class SystemIntegrationsUITests: XCTestCase {
    private let cleanDefaults = ["-agentAlerts.enabled", "NO", "-agentAlerts.breakThroughFocus", "NO",
                                 "-agentAlerts.showAgentName", "YES", "-agentAlerts.declinedIDs", "()",
                                 "-agentAlerts.snoozedIDs", "()", "-lockScreen.showMacName", "NO",
                                 "-lockScreen.sessionActivity", "YES"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + cleanDefaults
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: Settings

    @MainActor
    func testHomeOffersAlertsAndLockScreenAndTheSheetStartsQuiet() {
        let app = launch(["--ui-seed-pairing=Studio Mac", "--ui-x"])
        let row = app.buttons["home.agentAlerts"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Home lists Alerts & Lock Screen")
        row.tap()
        XCTAssertTrue(element(app, "agent.settings").waitForExistence(timeout: 5))
        for identifier in ["agent.settings.alerts", "agent.settings.focus", "agent.settings.name", "agent.settings.test",
                           "agent.settings.activity", "agent.settings.macname", "agent.settings.preview"] {
            XCTAssertTrue(element(app, identifier).exists, "The sheet is missing \(identifier)")
        }
        XCTAssertEqual(element(app, "agent.settings.alerts").value as? String, "0", "Alerts are off until the person turns them on")
        XCTAssertEqual(element(app, "agent.settings.macname").value as? String, "0", "The Mac's name is hidden by default")
        XCTAssertFalse(element(app, "agent.settings.test").isEnabled, "There is nothing to test until alerts are on")
        XCTAssertTrue(app.staticTexts["AGENT ALERTS · BETA"].exists || app.staticTexts["Agent alerts · Beta"].exists)
        attach("Alerts and Lock Screen settings")
    }

    /// The real switch: off to on goes through the phone's explanation and then iOS's question, and back.
    /// It takes no defaults from the command line, because a command-line default beats what the app writes.
    @MainActor
    func testTheSwitchTurnsAlertsOnThroughPrimingAndIOSAndOffAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x", "--ui-agent-settings"]
        app.launch()
        let toggle = element(app, "agent.settings.alerts")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let sendTest = element(app, "agent.settings.test")

        func waitForValue(_ expected: String, _ message: String) {
            let matches = NSPredicate(format: "value == %@", expected)
            expectation(for: matches, evaluatedWith: toggle)
            waitForExpectations(timeout: 15) { error in
                if error != nil { XCTFail(message) }
            }
        }

        if toggle.value as? String == "1" {
            toggle.tap()
            waitForValue("0", "The switch turns off")
        }
        XCTAssertFalse(sendTest.isEnabled, "Nothing to test while alerts are off")

        toggle.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 4) {
            attach("Priming before iOS asks")
            continueButton.tap()
        }
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) {
            attach("iOS asks")
            allow.tap()
        }
        waitForValue("1", "Alerts turn on once iOS allows them")
        XCTAssertTrue(sendTest.waitForExistence(timeout: 5))
        XCTAssertTrue(sendTest.isEnabled, "Send test alert works once alerts are on")
        attach("Alerts on")

        toggle.tap()
        waitForValue("0", "The switch turns alerts off again")
        XCTAssertFalse(sendTest.isEnabled)
    }

    @MainActor
    func testNotificationPrimingExplainsBeforeIOSAsks() {
        let app = launch(["--ui-priming-notifications"])
        let priming = element(app, "priming.notifications")
        XCTAssertTrue(priming.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["priming.continue"].exists || app.buttons["Continue"].exists,
                      "One Continue, per the HIG pre-alert pattern")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Continue'")).count, 1)
        XCTAssertTrue(app.staticTexts["Farside works fine without notifications"].exists
                      || app.staticTexts["FARSIDE WORKS FINE WITHOUT NOTIFICATIONS"].exists)
        attach("Notification priming")
    }

    // MARK: The sheet a tap opens

    @MainActor
    func testTheAlertSheetOffersOneWayInAndNotNowDeclines() {
        let app = launch(["--ui-seed-pairing=Studio Mac", "--ui-agent-alert=claude_code"])
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Claude Code needs you."].exists)
        XCTAssertTrue(app.buttons["agent.alert.open"].exists)
        XCTAssertEqual(app.buttons["agent.alert.open"].label, "Open your Mac")
        attach("Alert sheet")
        app.buttons["agent.alert.notNow"].tap()
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForNonExistence(timeout: 5), "Not now closes the sheet")
    }

    @MainActor
    func testAnAlertFromALinkNamesNoAgentAndATestAlertSaysSo() {
        let app = launch(["--ui-agent-alert=other:test"])
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Test alert received."].exists)
        XCTAssertEqual(app.buttons["agent.alert.open"].label, "Done")
        XCTAssertFalse(app.buttons["agent.alert.notNow"].exists, "A test has nothing to decline")
        attach("Test alert sheet")
    }

    @MainActor
    func testAnOldRequestIsStillOpenableAndSaysItMayHaveEnded() {
        let app = launch(["--ui-agent-alert=codex:old"])
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Codex needs you."].exists)
        XCTAssertTrue(app.staticTexts["This was asked a while ago. It may have ended, but you can still take a look."].exists)
        attach("Old alert sheet")
    }

    @MainActor
    func testOpenYourMacStartsConnectingButOnlyBecauseThePersonTappedIt() {
        let app = launch(["--ui-seed-pairing=Studio Mac", "--ui-agent-alert=claude_code"])
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Cancel connection"].exists, "Nothing connected before the tap")
        app.buttons["agent.alert.open"].tap()
        XCTAssertTrue(app.buttons["Cancel connection"].waitForExistence(timeout: 8), "The tap connected, by the same path as Connect")
        XCTAssertTrue(element(app, "agent.alert.sheet").waitForNonExistence(timeout: 5))
    }

    // MARK: Over a live session

    @MainActor
    func testDuringASessionAnAlertIsOneQuietBannerNotASheet() {
        let app = launch(["--ui-layout-check", "--ui-viewport-fill", "--ui-session-live", "--ui-agent-banner=codex"])
        let banner = element(app, "agent.alert.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Codex needs you"].exists)
        XCTAssertFalse(element(app, "agent.alert.sheet").exists, "The picture already shows the Mac")
        attach("Alert banner over a session")
        banner.buttons["Dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }
}

/// Invalid agent payloads still produce a system notification, but tapping it must never create an
/// in-app alert route. This separate env-gated test also proves the banner tap landed before accepting
/// the absence of a sheet, so a missed SpringBoard tap cannot be mistaken for correct rejection.
final class AgentAlertInvalidPushUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(environment["FARSIDE_PUSH_INJECTED"] == "1",
                          "Run through script/push-samples/verify-routing.sh")
        continueAfterFailure = false
    }

    @MainActor
    func testAnInvalidPushedAlertDismissesButRoutesNowhere() throws {
        let tapText = try XCTUnwrap(environment["FARSIDE_PUSH_TAP_TEXT"])
        let app = try launchWithAlertsOnAndSignalReady()
        let banner = springboard.staticTexts[tapText]
        XCTAssertTrue(banner.waitForExistence(timeout: 60),
                      "The pushed notification did not arrive: \(springboard.debugDescription.prefix(300))")

        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        let hittableExpectation = expectation(for: hittable, evaluatedWith: banner)
        XCTAssertEqual(XCTWaiter.wait(for: [hittableExpectation], timeout: 5), .completed,
                       "The invalid notification becomes tappable")
        attach("Invalid notification before tap")
        springboard.staticTexts[tapText].tap()

        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "The banner tap was handled")
        let sheet = app.descendants(matching: .any)["agent.alert.sheet"].firstMatch
        let unexpectedSheet = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: sheet)
        unexpectedSheet.isInverted = true
        wait(for: [unexpectedSheet], timeout: 4)
        XCTAssertFalse(sheet.exists, "An invalid payload must not create an agent alert route")
        attach("Invalid notification routed nowhere")
    }

    @MainActor
    private func launchWithAlertsOnAndSignalReady() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x", "--ui-request-notifications",
                               "-agentAlerts.enabled", "YES", "-agentAlerts.declinedIDs", "()",
                               "-agentAlerts.snoozedIDs", "()"]
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.agentAlerts"].waitForExistence(timeout: 10), "Home is showing")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        Thread.sleep(forTimeInterval: 1.0)

        let ready = environment["FARSIDE_PUSH_READY_FILE"] ?? "/tmp/farside-push-ready"
        try "ready".write(toFile: ready, atomically: true, encoding: .utf8)
        return app
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// Exercises each notification-category action through the real SpringBoard notification UI. The
/// routing harness launches one test at a time, waits for the ready-file handshake, then delivers a
/// sample with `simctl push`. Keeping these checks in their own env-gated class prevents ordinary UI
/// runs from waiting for a push that will never arrive.
final class AgentAlertActionPushUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(environment["FARSIDE_PUSH_ACTION_INJECTED"] == "1",
                          "Run through script/push-samples/verify-routing.sh")
        continueAfterFailure = false
    }

    @MainActor
    func testTheSelectedBannerActionDismissesWithoutOpeningTheAlert() throws {
        let tapText = try XCTUnwrap(environment["FARSIDE_PUSH_TAP_TEXT"])
        let action = try XCTUnwrap(environment["FARSIDE_PUSH_ACTION"])
        let actionLabel: String
        switch action {
        case "snooze": actionLabel = "Snooze 15 min"
        case "not-now": actionLabel = "Not now"
        default:
            XCTFail("Unknown push action: \(action)")
            return
        }

        let app = try launchWithAlertsOnAndSignalReady()
        let banner = springboard.staticTexts[tapText]
        XCTAssertTrue(banner.waitForExistence(timeout: 60),
                      "The pushed notification did not arrive: \(springboard.debugDescription.prefix(300))")
        banner.press(forDuration: 1.2)

        let snooze = springboard.buttons["Snooze 15 min"]
        let notNow = springboard.buttons["Not now"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 10), "The category offers Snooze 15 min")
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "The category offers Not now")
        attach("Actions before \(actionLabel)")

        let selected = springboard.buttons[actionLabel]
        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        let hittableExpectation = expectation(for: hittable, evaluatedWith: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [hittableExpectation], timeout: 5), .completed,
                       "\(actionLabel) becomes tappable")
        springboard.buttons[actionLabel].tap()

        let sheet = app.descendants(matching: .any)["agent.alert.sheet"].firstMatch
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5),
                      "\(actionLabel) removes the handled notification")
        let unexpectedSheet = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: sheet)
        unexpectedSheet.isInverted = true
        wait(for: [unexpectedSheet], timeout: 4)
        XCTAssertFalse(sheet.exists, "\(actionLabel) must not behave like a tap on the notification")
        attach("After \(actionLabel)")
    }

    @MainActor
    private func launchWithAlertsOnAndSignalReady() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x", "--ui-request-notifications",
                               "-agentAlerts.enabled", "YES", "-agentAlerts.declinedIDs", "()",
                               "-agentAlerts.snoozedIDs", "()"]
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.agentAlerts"].waitForExistence(timeout: 10), "Home is showing")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        Thread.sleep(forTimeInterval: 1.0)

        let ready = environment["FARSIDE_PUSH_READY_FILE"] ?? "/tmp/farside-push-ready"
        try "ready".write(toFile: ready, atomically: true, encoding: .utf8)
        return app
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
