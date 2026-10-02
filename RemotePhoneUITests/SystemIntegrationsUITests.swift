import XCTest

/// Alerts, the Lock Screen settings and notification routing, exercised in the app the way a person uses
/// it. Launch arguments starting with `-` override UserDefaults for the run only, so no test leaves a
/// choice behind for the next.
final class SystemIntegrationsUITests: XCTestCase {
    private let cleanDefaults = ["-agentAlerts.enabled", "NO", "-agentAlerts.breakThroughFocus", "NO",
                                 "-agentAlerts.declinedIDs", "()",
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
        for identifier in ["agent.settings.alerts", "agent.settings.focus", "agent.settings.test",
                           "agent.settings.activity", "agent.settings.macname", "agent.settings.preview"] {
            XCTAssertTrue(element(app, identifier).exists, "The sheet is missing \(identifier)")
        }
        XCTAssertEqual(element(app, "agent.settings.alerts").value as? String, "0", "Alerts are off until the person turns them on")
        XCTAssertEqual(element(app, "agent.settings.macname").value as? String, "0", "The Mac's name is hidden by default")
        XCTAssertFalse(element(app, "agent.settings.test").isEnabled, "There is nothing to test until alerts are on")
        let sendWatchTest = element(app, "agent.settings.testWatch")
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(sendWatchTest.exists, "The iPhone offers a delayed test alert for the Watch")
            XCTAssertFalse(sendWatchTest.isEnabled, "There is nothing to test on the Watch until alerts are on")
        } else {
            XCTAssertFalse(sendWatchTest.exists, "A Watch pairs only with an iPhone")
        }
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
        let sendWatchTest = element(app, "agent.settings.testWatch")
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone

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
        if isPhone {
            XCTAssertTrue(sendWatchTest.exists, "The iPhone offers a delayed test alert for the Watch")
            XCTAssertTrue(sendWatchTest.isEnabled, "Send test alert in 10 s works once alerts are on")
        } else {
            XCTAssertFalse(sendWatchTest.exists, "A Watch pairs only with an iPhone")
        }
        attach("Alerts on")

        toggle.tap()
        waitForValue("0", "The switch turns alerts off again")
        XCTAssertFalse(sendTest.isEnabled)
        if isPhone {
            XCTAssertFalse(sendWatchTest.isEnabled)
        } else {
            XCTAssertFalse(sendWatchTest.exists)
        }
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
        XCTAssertTrue(app.staticTexts["A task on your Mac needs you."].exists, "Fixed copy: no agent or product name")
        XCTAssertFalse(app.staticTexts["Claude Code needs you."].exists)
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
        XCTAssertTrue(app.staticTexts["A task on your Mac needs you."].exists)
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
        XCTAssertTrue(app.staticTexts["A task on your Mac needs you"].exists)
        XCTAssertFalse(element(app, "agent.alert.sheet").exists, "The picture already shows the Mac")
        attach("Alert banner over a session")
        banner.buttons["Dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }
}

/// Captures the real SpringBoard widget gallery/placement and the installed Share extension inside
/// Safari. These must be native-container captures: the test never renders a substitute widget or
/// extension view. Run on one of the b7 lane simulators with
/// TEST_RUNNER_FARSIDE_NATIVE_CONTAINERS=1; for the Safari test, first open a neutral public page
/// with `xcrun simctl openurl <UDID> https://www.apple.com/`.
final class NativeContainerSurfaceUITests: XCTestCase {
    private let allowedSimulatorIDs: Set<String> = [
        "23A869A5-D1DC-41F1-AF42-D127CA1DD133",
        "48AC7927-D6D8-4B44-A24B-BB49215FD575",
        "D724E9C9-7BEE-448C-A1A2-DDCFF03D226E",
        "A69BA21A-8F6A-48BD-972B-FFCCA74036DD",
        "419A9E16-E7F7-4269-8690-BD2E4DD4437C"
    ]

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_NATIVE_CONTAINERS"] == "1",
                          "Set TEST_RUNNER_FARSIDE_NATIVE_CONTAINERS=1 for native SpringBoard/Safari captures")
        #if targetEnvironment(simulator)
        let requestedID = ProcessInfo.processInfo.environment["FARSIDE_NATIVE_SIMULATOR_ID"] ?? ""
        let actualID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        try XCTSkipUnless(allowedSimulatorIDs.contains(requestedID)
                          && (actualID == nil || actualID == requestedID),
                          "Pass the destination UDID as TEST_RUNNER_FARSIDE_NATIVE_SIMULATOR_ID; only the five b7 simulator UDIDs are allowed")
        #else
        throw XCTSkip("Native container capture is simulator-only")
        #endif
        continueAfterFailure = true
    }

    @MainActor
    func testFarsideWidgetInNativeGalleryAndHomePlacement() throws {
        let names = ["widget-gallery-portrait", "widget-home-placement-portrait",
                     "widget-gallery-landscape", "widget-home-placement-landscape"]
        attachPlan(names)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        guard findFarsideHomeIcon() != nil else {
            missing("widget-gallery-portrait", "Farside app icon is absent from this simulator Home Screen")
            missing("widget-home-placement-portrait", "Cannot enter native widget flow without the installed Farside app")
            missing("widget-gallery-landscape", "Farside app icon is absent from this simulator Home Screen")
            missing("widget-home-placement-landscape", "Cannot enter native widget flow without the installed Farside app")
            return
        }

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let suffix = orientation == .portrait ? "portrait" : "landscape"
            XCUIDevice.shared.orientation = orientation
            if orientation == .landscapeLeft {
                let deadline = Date().addingTimeInterval(5)
                while springboard.frame.width <= springboard.frame.height && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.25)
                }
                guard springboard.frame.width > springboard.frame.height else {
                    missing("widget-gallery-landscape", "This simulator's SpringBoard Home Screen did not rotate to landscape")
                    missing("widget-home-placement-landscape", "Landscape Home Screen is unsupported on this simulator; no portrait duplicate was captured")
                    break
                }
            }
            guard let currentHomeIcon = findFarsideHomeIcon() else {
                missing("widget-gallery-\(suffix)", "Farside app icon was not visible on the active Home Screen page")
                missing("widget-home-placement-\(suffix)", "Could not reach the Farside app icon to begin native widget placement")
                continue
            }
            currentHomeIcon.press(forDuration: 1.2)
            let edit = springboard.buttons["Edit Home Screen"]
            let editMenu = edit.waitForExistence(timeout: 5) ? edit : springboard.buttons["Edit"]
            guard editMenu.waitForExistence(timeout: 3) else {
                missing("widget-gallery-\(suffix)", "SpringBoard did not expose Edit Home Screen or Edit from the Farside icon")
                missing("widget-home-placement-\(suffix)", "Native Home Screen edit menu was unavailable")
                continue
            }
            editMenu.tap()
            let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget' OR label == '+'")).firstMatch
            guard add.waitForExistence(timeout: 6) else {
                missing("widget-gallery-\(suffix)", "SpringBoard edit mode did not expose Add Widget")
                missing("widget-home-placement-\(suffix)", "SpringBoard widget gallery could not be opened")
                continue
            }
            add.tap()
            let search = springboard.searchFields.firstMatch
            guard search.waitForExistence(timeout: 8) else {
                missing("widget-gallery-\(suffix)", "Native widget gallery opened without an accessible search field")
                missing("widget-home-placement-\(suffix)", "Could not select Farside in the native widget gallery")
                continue
            }
            search.tap()
            search.typeText("Farside")
            let galleryApp = springboard.staticTexts["Farside"].firstMatch
            guard galleryApp.waitForExistence(timeout: 8) else {
                missing("widget-gallery-\(suffix)", "Native widget gallery search returned no Farside provider")
                missing("widget-home-placement-\(suffix)", "No Farside widget was available to place")
                continue
            }
            galleryApp.tap()
            let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
            var galleryCaptured = false
            if addWidget.waitForExistence(timeout: 5) {
                attach("widget-gallery-\(suffix)")
                galleryCaptured = true
                addWidget.tap()
            } else {
                let plus = springboard.buttons["+"]
                if plus.waitForExistence(timeout: 3) { plus.tap() }
            }
            let done = springboard.buttons["Done"]
            if done.waitForExistence(timeout: 5) { done.tap() }

            let galleryDismissed = !search.exists && !addWidget.exists && !springboard.buttons["Done"].exists
            let appIconRestored = springboard.icons["Farside"].waitForExistence(timeout: 3)
                && springboard.icons["Farside"].isHittable
            if galleryDismissed && appIconRestored && hasFarsideWidgetRoot() {
                attach("widget-home-placement-\(suffix)")
            } else {
                missing("widget-home-placement-\(suffix)",
                        "Placement was not verified: galleryDismissed=\(galleryDismissed), appIconRestored=\(appIconRestored), widgetRoot=\(hasFarsideWidgetRoot())")
            }
            if !galleryCaptured {
                missing("widget-gallery-\(suffix)", "SpringBoard did not expose the native Add Widget provider preview")
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func findFarsideHomeIcon() -> XCUIElement? {
        for page in 0..<5 {
            let icon = springboard.icons["Farside"]
            if icon.waitForExistence(timeout: page == 0 ? 4 : 1) && icon.isHittable {
                return icon
            }
            if page < 4 { springboard.swipeLeft() }
        }
        return nil
    }

    @MainActor
    func testFarsideShareExtensionFromSafari() throws {
        let names = ["share-extension-safari-portrait", "share-extension-safari-landscape"]
        attachPlan(names)
        XCUIDevice.shared.orientation = .portrait
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        guard safari.wait(for: .runningForeground, timeout: 8) else {
            missing("share-extension-safari-portrait", "Safari did not become the foreground app; prepare with simctl openurl https://www.apple.com/")
            missing("share-extension-safari-landscape", "Safari did not become the foreground app")
            return
        }
        let share = safari.buttons["Share"]
        guard share.waitForExistence(timeout: 8) else {
            missing("share-extension-safari-portrait", "Safari Share control is unavailable; prepare a loaded neutral public page")
            missing("share-extension-safari-landscape", "Safari Share control is unavailable")
            return
        }
        share.tap()
        let more = springboard.buttons["More"]
        if more.waitForExistence(timeout: 5) { more.tap() }
        let farside = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Farside'")).firstMatch
        guard farside.waitForExistence(timeout: 10) else {
            missing("share-extension-safari-portrait", "Safari share sheet did not offer the installed Farside share extension")
            missing("share-extension-safari-landscape", "Safari share sheet did not offer the installed Farside share extension")
            return
        }
        farside.tap()
        let extensionApp = XCUIApplication(bundleIdentifier: "com.roshan.PocketDesk.Remote.Share")
        guard waitForShareRoot(safari, extensionApp, timeout: 10) else {
            missing("share-extension-safari-portrait", "Extension selection did not expose the Send to Mac root in Safari's native share sheet")
            missing("share-extension-safari-landscape", "Extension selection did not expose a valid Farside share-sheet root")
            return
        }
        if waitForOrientation(of: safari, landscape: false, timeout: 5)
            && waitForShareRoot(safari, extensionApp, timeout: 3) {
            attach("share-extension-safari-portrait")
        } else {
            missing("share-extension-safari-portrait", "Safari did not reach portrait frame dimensions before capture")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        if waitForOrientation(of: safari, landscape: true, timeout: 5)
            && waitForShareRoot(safari, extensionApp, timeout: 3) {
            attach("share-extension-safari-landscape")
        } else {
            missing("share-extension-safari-landscape",
                    "Landscape capture was not verified: Safari did not retain a valid extension root in landscape frame dimensions")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func hasFarsideWidgetRoot() -> Bool {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Connect to Your Mac' OR identifier CONTAINS[c] 'ConnectWidget'"))
            .firstMatch.exists
    }

    @MainActor
    private func waitForShareRoot(_ safari: XCUIApplication, _ extensionApp: XCUIApplication,
                                  timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == 'Send to My Mac' OR identifier == 'share.send'")
        let candidates = [
            safari.descendants(matching: .any).matching(predicate).firstMatch,
            springboard.descendants(matching: .any).matching(predicate).firstMatch,
            extensionApp.descendants(matching: .any).matching(predicate).firstMatch
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if candidates.contains(where: { $0.exists && $0.isHittable }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForOrientation(of app: XCUIApplication, landscape: Bool,
                                    timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let frame = app.frame
            if landscape ? frame.width > frame.height : frame.height > frame.width { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private func attachPlan(_ names: [String]) {
        let attachment = XCTAttachment(string: names.joined(separator: "\n"))
        attachment.name = "capture-plan"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func missing(_ name: String, _ reason: String) {
        let diagnostic = XCTAttachment(string: reason)
        diagnostic.name = "missing-state-reason-\(name)"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "missing-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
