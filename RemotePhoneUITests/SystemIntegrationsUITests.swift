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

    @MainActor
    func testNotificationPrimingExplainsBeforeIOSAsks() {
        let app = launch(["--ui-priming-notifications"])
        let priming = element(app, "priming.notifications")
        XCTAssertTrue(priming.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["priming.continue"].exists, "One Continue, per the HIG pre-alert pattern")
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
