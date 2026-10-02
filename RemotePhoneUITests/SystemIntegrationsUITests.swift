import XCTest
import UIKit

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
        "D5594C97-5480-4F5F-A1D1-70306523A92E",
        "D724E9C9-7BEE-448C-A1A2-DDCFF03D226E",
        "A69BA21A-8F6A-48BD-972B-FFCCA74036DD",
        "419A9E16-E7F7-4269-8690-BD2E4DD4437C"
    ]

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let ipadSimulatorIDs: Set<String> = [
        "A69BA21A-8F6A-48BD-972B-FFCCA74036DD",
        "419A9E16-E7F7-4269-8690-BD2E4DD4437C"
    ]

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
                     "widget-context-menu-portrait", "widget-gallery-landscape",
                     "widget-home-placement-landscape", "widget-context-menu-landscape"]
        attachPlan(names)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        guard findFarsideHomeIcon() != nil else {
            missing("widget-gallery-portrait", "Farside app icon is absent from this simulator Home Screen")
            missing("widget-home-placement-portrait", "Cannot enter native widget flow without the installed Farside app")
            missing("widget-context-menu-portrait", "No visible Farside widget was available to target")
            missing("widget-gallery-landscape", "Farside app icon is absent from this simulator Home Screen")
            missing("widget-home-placement-landscape", "Cannot enter native widget flow without the installed Farside app")
            missing("widget-context-menu-landscape", "No visible Farside widget was available to target")
            return
        }
        var widgetPlaced = farsideWidgetElement() != nil

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
                    missing("widget-context-menu-landscape", "Landscape Home Screen is unsupported; no landscape widget context menu was captured")
                    break
                }
            }
            if widgetPlaced {
                if farsideWidgetElement() != nil {
                    attach("widget-home-placement-\(suffix)")
                    captureWidgetContextMenu(suffix: suffix, landscape: orientation == .landscapeLeft)
                } else {
                    missing("widget-home-placement-\(suffix)", "Previously placed Farside widget root is not visible and hittable in this orientation")
                    missing("widget-context-menu-\(suffix)", "No visible, hittable Farside widget root was available for a bounded long press")
                }
                captureFarsideWidgetGallery(suffix: suffix, landscape: orientation == .landscapeLeft)
                continue
            }
            guard let currentHomeIcon = findFarsideHomeIcon() else {
                missing("widget-gallery-\(suffix)", "Farside app icon was not visible on the active Home Screen page")
                missing("widget-home-placement-\(suffix)", "Could not reach the Farside app icon to begin native widget placement")
                missing("widget-context-menu-\(suffix)", "Placement failed before a Farside widget could be safely targeted")
                continue
            }
            currentHomeIcon.press(forDuration: 1.2)
            let edit = springboard.buttons["Edit Home Screen"]
            let editMenu = edit.waitForExistence(timeout: 5) ? edit : springboard.buttons["Edit"]
            guard editMenu.waitForExistence(timeout: 3) else {
                missing("widget-gallery-\(suffix)", "SpringBoard did not expose Edit Home Screen or Edit from the Farside icon")
                missing("widget-home-placement-\(suffix)", "Native Home Screen edit menu was unavailable")
                missing("widget-context-menu-\(suffix)", "Placement did not reach a visible Farside widget")
                continue
            }
            editMenu.tap()
            let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget' OR label == '+'")).firstMatch
            guard add.waitForExistence(timeout: 6) else {
                missing("widget-gallery-\(suffix)", "SpringBoard edit mode did not expose Add Widget")
                missing("widget-home-placement-\(suffix)", "SpringBoard widget gallery could not be opened")
                missing("widget-context-menu-\(suffix)", "Placement did not reach a visible Farside widget")
                continue
            }
            add.tap()
            let search = springboard.searchFields.firstMatch
            guard search.waitForExistence(timeout: 8) else {
                missing("widget-gallery-\(suffix)", "Native widget gallery opened without an accessible search field")
                missing("widget-home-placement-\(suffix)", "Could not select Farside in the native widget gallery")
                missing("widget-context-menu-\(suffix)", "Placement did not reach a visible Farside widget")
                continue
            }
            search.tap()
            search.typeText("Farside")
            let galleryApp = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Farside")).firstMatch
            guard galleryApp.waitForExistence(timeout: 8) else {
                missing("widget-gallery-\(suffix)", "Native widget gallery search returned no Farside provider")
                missing("widget-home-placement-\(suffix)", "No Farside widget was available to place")
                missing("widget-context-menu-\(suffix)", "No Farside widget could be placed or safely targeted")
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
            let widget = farsideWidgetElement()
            widgetPlaced = galleryDismissed && appIconRestored && widget != nil
            if widgetPlaced {
                attach("widget-home-placement-\(suffix)")
            } else {
                missing("widget-home-placement-\(suffix)",
                        "Placement was not verified: galleryDismissed=\(galleryDismissed), appIconRestored=\(appIconRestored), visibleHittableWidgetRoot=\(widget != nil)")
            }
            if !galleryCaptured {
                missing("widget-gallery-\(suffix)", "SpringBoard did not expose the native Add Widget provider preview")
            }
            if widgetPlaced {
                captureWidgetContextMenu(suffix: suffix, landscape: orientation == .landscapeLeft)
            } else {
                missing("widget-context-menu-\(suffix)", "Placement was not verified; no Home Screen widget context menu was attempted")
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
    private func farsideWidgetElement() -> XCUIElement? {
        let matches = springboard.descendants(matching: .any)
            .matching(NSPredicate(format:
                "label == 'Connect to Your Mac' OR label BEGINSWITH 'Connect to Your Mac. Last seen ' OR " +
                "label == 'Connect to Studio Mac' OR label BEGINSWITH 'Connect to Studio Mac. Last seen '"))
            .allElementsBoundByIndex
        return matches.first(where: { $0.exists && $0.isHittable })
    }

    @MainActor
    private func captureWidgetContextMenu(suffix: String, landscape: Bool) {
        let frame = springboard.frame
        let orientationMatches = landscape ? frame.width > frame.height : frame.height > frame.width
        guard orientationMatches else {
            missing("widget-context-menu-\(suffix)",
                    "SpringBoard frame does not match requested \(landscape ? "landscape" : "portrait") orientation")
            return
        }
        guard let widget = farsideWidgetElement() else {
            missing("widget-context-menu-\(suffix)", "The Connect to Your Mac widget root was not visible and hittable")
            return
        }
        widget.press(forDuration: 1.2)
        let menuLabels = ["Remove Widget", "Edit Widget"]
        let menuAction = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", menuLabels))
            .firstMatch
        if menuAction.waitForExistence(timeout: 4) && menuAction.isHittable {
            attach("widget-context-menu-\(suffix)")
        } else {
            missing("widget-context-menu-\(suffix)",
                    "Long press on the owned Connect to Your Mac widget exposed no widget-specific Edit Widget or Remove Widget action")
        }
        XCUIDevice.shared.press(.home)
    }

    /// Reopens the real provider preview from an existing Home Screen without adding a duplicate.
    @MainActor
    private func captureFarsideWidgetGallery(suffix: String, landscape: Bool) {
        defer { XCUIDevice.shared.press(.home) }
        let frame = springboard.frame
        let orientationMatches = landscape ? frame.width > frame.height : frame.height > frame.width
        guard orientationMatches else {
            missing("widget-gallery-\(suffix)",
                    "SpringBoard frame does not match requested \(landscape ? "landscape" : "portrait") gallery orientation")
            return
        }
        guard let icon = findFarsideHomeIcon() else {
            missing("widget-gallery-\(suffix)", "Could not find the Farside app icon to reopen the native widget provider gallery")
            return
        }
        icon.press(forDuration: 1.2)
        let editHome = springboard.buttons["Edit Home Screen"]
        let edit = editHome.waitForExistence(timeout: 5) ? editHome : springboard.buttons["Edit"]
        guard edit.waitForExistence(timeout: 3) && edit.isHittable else {
            missing("widget-gallery-\(suffix)", "SpringBoard exposed neither Edit Home Screen nor Edit")
            return
        }
        edit.tap()
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget' OR label == '+'")).firstMatch
        guard add.waitForExistence(timeout: 6) && add.isHittable else {
            missing("widget-gallery-\(suffix)", "Home Screen edit mode did not expose the native Add Widget control")
            return
        }
        add.tap()
        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) && search.isHittable else {
            missing("widget-gallery-\(suffix)", "Native widget gallery did not expose a hittable provider search field")
            return
        }
        search.tap()
        search.typeText("Farside")
        let provider = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Farside")).firstMatch
        guard provider.waitForExistence(timeout: 8) && provider.isHittable else {
            missing("widget-gallery-\(suffix)", "Native widget gallery search did not expose a hittable Farside provider")
            return
        }
        provider.tap()
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        let galleryFrame = springboard.frame
        let galleryHasRequestedOrientation = landscape
            ? galleryFrame.width > galleryFrame.height
            : galleryFrame.height > galleryFrame.width
        guard galleryHasRequestedOrientation && addWidget.waitForExistence(timeout: 5) && addWidget.isHittable else {
            missing("widget-gallery-\(suffix)",
                    "Farside provider Add Widget preview was not visible and hittable in the requested SpringBoard orientation")
            return
        }
        attach("widget-gallery-\(suffix)")
        // Deliberately leave Add Widget untouched: the existing Home Screen placement is retained.
    }

    /// Attempts only the real iPadOS windowing controls. A compact-window screenshot is attached
    /// only after the app's verified Home root remains visible in an actually narrower app frame.
    @MainActor
    func testIPadNativeWindowingMenuAndCompactWindow() throws {
        let planned = ["landscape-ipad-windowing-menu", "landscape-ipad-compact-window"]
        attachPlan(planned)
        let requestedID = ProcessInfo.processInfo.environment["FARSIDE_NATIVE_SIMULATOR_ID"] ?? ""
        try XCTSkipUnless(ipadSimulatorIDs.contains(requestedID),
                          "This native windowing attempt is restricted to the b7 iPad Pro 11/13 simulators")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-last-reached", "--ui-x"]
        app.launch()
        guard app.buttons["home.agentAlerts"].waitForExistence(timeout: 10) else {
            missing("landscape-ipad-windowing-menu", "Seeded Farside Home root did not appear in the iPad app")
            missing("landscape-ipad-compact-window", "Cannot attempt windowing without the verified Home root")
            attachAccessibilityTree("ipad-windowing-no-home-tree", app)
            return
        }

        guard waitForOrientation(of: app, landscape: true, timeout: 5) else {
            missing("landscape-ipad-windowing-menu", "Farside did not reach an observed landscape app frame before native menu capture")
            missing("landscape-ipad-compact-window", "A verified landscape baseline was unavailable for measuring native tile geometry")
            return
        }
        let baselineWidth = app.frame.width
        let controlLabels = ["Window Controls", "Show Multitasking Menu",
                             "Multitasking Controls", "Window menu"]
        let controlPredicate = NSPredicate(format: "label IN %@", controlLabels)
        let control = app.descendants(matching: .any).matching(controlPredicate).firstMatch
        guard control.waitForExistence(timeout: 5) && control.isHittable else {
            missing("landscape-ipad-windowing-menu", "No accessible native Window Controls or Multitasking Menu appeared in the landscape app")
            missing("landscape-ipad-compact-window", "No public native window-control entry point was exposed; no synthetic compact canvas was used")
            attachAccessibilityTree("ipad-windowing-controls-unavailable-tree", app)
            return
        }
        control.tap()
        let menuActions = ["Tile Left", "Tile Right", "Tile to Left", "Tile to Right",
                           "Move to Left Side", "Move to Right Side", "Half Screen"]
        let actionPredicate = NSPredicate(format: "label IN %@", menuActions)
        let nativeAction = springboard.descendants(matching: .any).matching(actionPredicate).firstMatch
        let appAction = app.descendants(matching: .any).matching(actionPredicate).firstMatch
        let action = nativeAction.waitForExistence(timeout: 4) ? nativeAction : appAction
        guard action.exists && action.isHittable else {
            missing("landscape-ipad-windowing-menu", "Native window controls opened, but exposed no exact half-screen/tile action")
            missing("landscape-ipad-compact-window", "No safe half-screen native action was available to select")
            attachAccessibilityTree("ipad-windowing-menu-tree", springboard)
            attachAccessibilityTree("ipad-windowing-app-tree", app)
            return
        }
        attach("landscape-ipad-windowing-menu")
        action.tap()
        let deadline = Date().addingTimeInterval(8)
        var compact = false
        while Date() < deadline {
            let frame = app.frame
            compact = app.buttons["home.agentAlerts"].exists
                && frame.width < baselineWidth * 0.80
                && frame.width < frame.height
            if compact { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if compact {
            attach("landscape-ipad-compact-window")
        } else {
            missing("landscape-ipad-compact-window",
                    "Native tile action did not leave the verified Farside Home root in a narrow app frame")
            attachAccessibilityTree("ipad-compact-window-unverified-tree", app)
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFarsideShareExtensionFromSafari() throws {
        let names = ["share-host-sheet-portrait", "share-host-sheet-landscape",
                     "share-extension-safari-portrait", "share-extension-safari-landscape"]
        attachPlan(names)
        XCUIDevice.shared.orientation = .portrait
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        guard safari.wait(for: .runningForeground, timeout: 8) else {
            missing("share-host-sheet-portrait", "Safari did not become the foreground app")
            missing("share-host-sheet-landscape", "Safari did not become the foreground app")
            missing("share-extension-safari-portrait", "Safari did not become the foreground app; prepare with simctl openurl https://www.apple.com/")
            missing("share-extension-safari-landscape", "Safari did not become the foreground app")
            return
        }
        let share = safari.buttons["Share"]
        guard share.waitForExistence(timeout: 8) else {
            missing("share-host-sheet-portrait", "Safari Share control is unavailable")
            missing("share-host-sheet-landscape", "Safari Share control is unavailable")
            missing("share-extension-safari-portrait", "Safari Share control is unavailable; prepare a loaded neutral public page")
            missing("share-extension-safari-landscape", "Safari Share control is unavailable")
            return
        }
        share.tap()
        let activityPredicate = NSPredicate(format: "label == 'Send to My Mac' OR label == 'Farside'")
        let activities = [safari, springboard].map {
            $0.descendants(matching: .any).matching(activityPredicate).firstMatch
        }
        if !activities.contains(where: { $0.exists && $0.isHittable }) {
            let moreButtons = [safari.buttons["More"], springboard.buttons["More"]]
            for more in moreButtons where more.waitForExistence(timeout: 3) && more.isHittable {
                more.tap()
                break
            }
        }
        let deadline = Date().addingTimeInterval(10)
        var selection: XCUIElement?
        repeat {
            selection = activities.first(where: { $0.exists && $0.isHittable })
            if selection != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        guard let farside = selection else {
            missing("share-host-sheet-portrait", "Safari share sheet did not expose a visible, hittable Send to My Mac/Farside extension entry")
            missing("share-host-sheet-landscape", "No verified extension entry was available for a landscape native share-sheet capture")
            missing("share-extension-safari-portrait", "Safari share sheet did not offer the installed Farside share extension")
            missing("share-extension-safari-landscape", "Safari share sheet did not offer the installed Farside share extension")
            return
        }
        if waitForOrientation(of: safari, landscape: false, timeout: 5) && farside.exists && farside.isHittable {
            attach("share-host-sheet-portrait")
        } else {
            missing("share-host-sheet-portrait", "The native Safari sheet and its hittable Farside entry were not verified in portrait")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        if waitForOrientation(of: safari, landscape: true, timeout: 5)
            && farside.exists && farside.isHittable {
            attach("share-host-sheet-landscape")
        } else {
            missing("share-host-sheet-landscape", "The native Safari sheet did not retain its hittable Farside entry in landscape")
        }
        XCUIDevice.shared.orientation = .portrait
        guard waitForOrientation(of: safari, landscape: false, timeout: 5)
                && farside.exists && farside.isHittable else {
            missing("share-extension-safari-portrait", "Share extension was not selected because the validated native Safari entry did not return hittable in portrait")
            missing("share-extension-safari-landscape", "Share extension was not selected because its native Safari entry did not return hittable in portrait")
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
    private func waitForShareRoot(_ safari: XCUIApplication, _ extensionApp: XCUIApplication,
                                  timeout: TimeInterval) -> Bool {
        let candidates = [safari, springboard, extensionApp]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for app in candidates {
                let close = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier == 'share.close'")).firstMatch
                let heading = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == 'Send to My Mac'")).firstMatch
                if close.exists && close.isHittable && heading.exists && heading.isHittable {
                    return true
                }
            }
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
    private func attachAccessibilityTree(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
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
