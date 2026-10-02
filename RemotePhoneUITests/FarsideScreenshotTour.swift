import XCTest
import UIKit

/// Screenshots of every redesigned screen, attached to the test result. Skipped unless the
/// runner is started with `TEST_RUNNER_FARSIDE_SCREENSHOTS=1`, so ordinary runs stay fast.
final class FarsideScreenshotTour: XCTestCase {
    private struct Shot {
        let name: String
        let arguments: [String]
        var landscape = false
        var wait: TimeInterval = 0.35
    }

    private let basicShots: [Shot] = [
        Shot(name: "home-empty", arguments: ["--ui-x"]),
        Shot(name: "home", arguments: ["--ui-demo-mac", "--ui-last-reached"]),
        Shot(name: "home-connecting", arguments: ["--ui-demo-mac", "--ui-last-reached", "--ui-status=Authenticating_your_Mac…"], wait: 3.5),
        Shot(name: "pairing-camera-priming", arguments: ["--ui-pairing-scan", "--ui-camera-priming"]),
        Shot(name: "pairing-expired-code", arguments: ["--ui-pairing-paste", "--ui-pairing-expired"]),
        Shot(name: "pairing-success", arguments: ["--ui-pairing-scan", "--ui-camera-denied", "--ui-pairing-burst"], wait: 3),
        Shot(name: "priming-local-network", arguments: ["--ui-priming-network"]),
        Shot(name: "priming-microphone", arguments: ["--ui-priming-mic"]),
        Shot(name: "coach-move", arguments: ["--ui-coach"]),
        Shot(name: "coach-click", arguments: ["--ui-coach", "--ui-coach-lesson=1"]),
        Shot(name: "coach-scroll", arguments: ["--ui-coach", "--ui-coach-lesson=2"]),
        Shot(name: "coach-zoom", arguments: ["--ui-coach", "--ui-coach-lesson=4"]),
        Shot(name: "coach-complete", arguments: ["--ui-coach", "--ui-coach-lesson=5"]),
        Shot(name: "priming-notifications", arguments: ["--ui-priming-notifications"]),
        Shot(name: "priming-camera", arguments: ["--ui-priming-camera"]),
        Shot(name: "picture", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-controls-settings", "--ui-controls-page=picture"], wait: 4),
        Shot(name: "data-warning", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-dock-open", "--ui-data-warning"], wait: 4),
        Shot(name: "coach-drag", arguments: ["--ui-coach", "--ui-coach-lesson=3"]),
        Shot(name: "error-napping", arguments: ["--ui-demo-mac", "--ui-error=napping"], wait: 3),
        Shot(name: "error-unreachable", arguments: ["--ui-demo-mac", "--ui-error=unreachable"], wait: 3),
        Shot(name: "error-needs-plan", arguments: ["--ui-demo-mac", "--ui-error=needsPlan"], wait: 3),
        Shot(name: "troubleshoot", arguments: ["--ui-demo-mac", "--ui-troubleshoot"]),
        Shot(name: "anywhere-paywall", arguments: ["--ui-paywall"], wait: 4),
        Shot(name: "session", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-pointer-preview", "--ui-pointer-accent-preview"]),
        Shot(name: "session-resolution-lock", arguments: ["--ui-layout-check", "--ui-lock-stage=1"]),
        Shot(name: "session-reconnecting", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-reconnecting"]),
        Shot(name: "session-sharing-stopped", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-issue-sharing"]),
        Shot(name: "dock", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-dock-open", "--ui-pointer-preview"]),
        Shot(name: "dock-dictation", arguments: ["--ui-layout-check", "--ui-voice-preview-check"]),
        Shot(name: "dock-clipboard", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-clipboard-row"]),
        Shot(name: "keyboard", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-keyboard-check"], wait: 3),
        Shot(name: "controls", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-curtain-preview", "--ui-vitals=battery12",
                                           "--ui-viewport-fill", "--ui-pointer-preview", "--ui-controls-check"], wait: 5),
        Shot(name: "controls-settings", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                                                    "--ui-viewport-fill", "--ui-controls-settings"], wait: 5),
        Shot(name: "controls-settings-pointer", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                                                            "--ui-viewport-fill", "--ui-controls-settings", "--ui-controls-page=pointer"], wait: 5),
        Shot(name: "hold-finger", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-pointer-preview",
                                              "--ui-hold-preview=finger"], wait: 5),
        Shot(name: "hold-explicit", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-pointer-preview",
                                                "--ui-hold-preview=explicit"], wait: 5),
        Shot(name: "concealed", arguments: ["--ui-layout-check", "--ui-background-concealed-check"]),
        Shot(name: "landscape-home", arguments: ["--ui-demo-mac", "--ui-last-reached"], landscape: true),
        Shot(name: "landscape-session", arguments: ["--ui-layout-check", "--ui-viewport-fit", "--ui-pointer-preview"], landscape: true),
        Shot(name: "landscape-dock", arguments: ["--ui-layout-check", "--ui-viewport-fit", "--ui-dock-open"], landscape: true),
        Shot(name: "landscape-dictation", arguments: ["--ui-layout-check", "--ui-voice-preview-check"], landscape: true),
        Shot(name: "landscape-keyboard", arguments: ["--ui-layout-check", "--ui-viewport-fill", "--ui-keyboard-check"], landscape: true, wait: 3),
        Shot(name: "landscape-controls-settings", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                                                              "--ui-viewport-fill", "--ui-controls-settings"], landscape: true, wait: 5),
        Shot(name: "landscape-controls", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                                                     "--ui-viewport-fill", "--ui-pointer-preview", "--ui-controls-check"], landscape: true, wait: 5),
        Shot(name: "landscape-coach", arguments: ["--ui-coach"], landscape: true)
    ]

    // Keep the older landscape names as filter aliases. In the full orientation tour each
    // portrait entry is repeated instead, so these aliases do not produce duplicate images.
    private var shots: [Shot] {
        let probe = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-viewport-fill"]
        let home = ["--ui-demo-mac", "--ui-last-reached", "--ui-seed-pairing=Studio Mac"]
        let extra = [
            Shot(name: "home-help-menu", arguments: home),
            Shot(name: "home-connection-details", arguments: home),
            Shot(name: "home-legal", arguments: home),
            Shot(name: "home-security", arguments: home),
            Shot(name: "home-server-data", arguments: home),
            Shot(name: "home-server-data-confirm", arguments: home),
            Shot(name: "home-forget-confirm", arguments: home),
            Shot(name: "home-paired-macs", arguments: home),
            Shot(name: "home-session-check", arguments: home),
            Shot(name: "home-session-support", arguments: home),
            Shot(name: "home-session-blocker-options", arguments: home),
            Shot(name: "home-system-connect-prompt", arguments: home),
            Shot(name: "home-alert-settings", arguments: ["--ui-agent-settings"]),
            Shot(name: "agent-alert", arguments: ["--ui-seed-pairing=Studio Mac", "--ui-agent-alert=claude_code"]),
            Shot(name: "agent-alert-test", arguments: ["--ui-seed-pairing=Studio Mac", "--ui-agent-alert=claude_code:test"]),
            Shot(name: "agent-alert-old", arguments: ["--ui-seed-pairing=Studio Mac", "--ui-agent-alert=claude_code:old"]),
            Shot(name: "agent-banner", arguments: probe + ["--ui-session-live", "--ui-agent-banner=codex"]),
            Shot(name: "home-low-battery", arguments: ["--ui-demo-mac", "--ui-last-battery=4"]),
            Shot(name: "pairing-paste", arguments: ["--ui-pairing-paste"]),
            Shot(name: "pairing-malformed-code", arguments: ["--ui-pairing-paste"]),
            Shot(name: "pairing-camera-unavailable", arguments: ["--ui-pairing-scan", "--ui-camera-priming"]),
            Shot(name: "pairing-camera-denied", arguments: ["--ui-pairing-scan", "--ui-camera-denied"]),
            Shot(name: "pairing-scanning", arguments: ["--ui-pairing-scan", "--ui-camera-priming"]),
            Shot(name: "couch", arguments: probe + ["--ui-couch", "--ui-demo-mac"]),
            Shot(name: "couch-controls", arguments: probe + ["--ui-couch", "--ui-demo-mac", "--ui-controls-check", "--ui-vitals=battery12"]),
            Shot(name: "big-text-pending", arguments: probe + ["--ui-controls-check"]),
            Shot(name: "big-text-selected", arguments: probe + ["--ui-controls-check"]),
            Shot(name: "controls-lan-wake", arguments: probe + ["--ui-controls-check"]),
            Shot(name: "controls-keyboard-view-options", arguments: probe + ["--ui-controls-settings", "--ui-controls-page=view"]),
            Shot(name: "controls-precision-tap-options", arguments: probe + ["--ui-controls-settings", "--ui-controls-page=touch"]),
            Shot(name: "controls-shortcuts-expanded", arguments: probe + ["--ui-controls-settings", "--ui-controls-page=keyboard", "-remapReservedShortcuts", "YES"]),
            Shot(name: "controls-diagnostics-old-mac", arguments: probe + ["--ui-controls-settings", "--ui-controls-page=diagnostics", "--ui-vitals=old"])
        ]
        let pages = ["display", "touch", "view", "clipboard", "keyboard", "steer", "diagnostics"].map {
            Shot(name: "controls-settings-\($0)", arguments: probe + ["--ui-controls-settings", "--ui-controls-page=\($0)", "--ui-vitals=battery12"])
        }
        let errors = ["busy", "locked", "codeRejected", "declined", "approvalTimedOut", "verifyFailed",
                      "relayUnavailable", "connectionLost", "sessionGlitch", "anywhereUnverified", "couchNotLocal", "couchControlOff"].map {
            Shot(name: "error-\($0)", arguments: ["--ui-demo-mac", "--ui-error=\($0)"])
        }
        return basicShots + extra + pages + errors
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_FARSIDE_SCREENSHOTS=1 to capture the screenshot tour")
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// The host driver opens the public URL on the owned simulator after each readiness marker.
    /// Opening it from this background UI-test runner is refused by the system trust check.
    @MainActor
    func testCaptureExternallyOpenedPublicConnectPrompt() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["FARSIDE_EXTERNAL_PUBLIC_URL_INJECTED"] == "1",
                          "Set TEST_RUNNER_FARSIDE_EXTERNAL_PUBLIC_URL_INJECTED=1 for host-injected public URL captures")
        #if targetEnvironment(simulator)
        let allowedSimulatorIDs: Set<String> = [
            "23A869A5-D1DC-41F1-AF42-D127CA1DD133",
            "48AC7927-D6D8-4B44-A24B-BB49215FD575",
            "D5594C97-5480-4F5F-A1D1-70306523A92E",
            "D724E9C9-7BEE-448C-A1A2-DDCFF03D226E",
            "A69BA21A-8F6A-48BD-972B-FFCCA74036DD",
            "419A9E16-E7F7-4269-8690-BD2E4DD4437C"
        ]
        let simulatorID = environment["FARSIDE_NATIVE_SIMULATOR_ID"] ?? ""
        try XCTSkipUnless(allowedSimulatorIDs.contains(simulatorID)
                          && environment["SIMULATOR_UDID"] == simulatorID,
                          "Public URL injection requires a known simulator ID matching actual SIMULATOR_UDID")
        let names = ["home-system-connect-prompt", "landscape-home-system-connect-prompt"]
        let plan = XCTAttachment(string: names.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)
        let app = XCUIApplication()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for (index, orientation) in [UIDeviceOrientation.portrait, .landscapeLeft].enumerated() {
            let name = names[index]
            let phase = index == 0 ? "portrait" : "landscape"
            XCUIDevice.shared.orientation = orientation
            // This in-memory pairing suppresses surprise onboarding without replacing Home,
            // its system-route modifier, or the production ConnectPromptSheet presenter.
            app.launchArguments = ["--ui-seed-pairing=Studio Mac"]
            app.launch()
            let home = element("phone.home", in: app)
            let prompt = element("connectPrompt", in: app)
            let connect = app.buttons["connectPrompt.connect"]
            let close = app.buttons["connectPrompt.close"]
            let seededName = app.staticTexts["Studio Mac"]
            guard home.waitForExistence(timeout: 4), seededName.exists, !prompt.exists else {
                _ = missing("Seeded Studio Mac Home was not ready for external \(phase) public URL injection")
                attach("missing-" + name)
                app.terminate()
                continue
            }
            guard captureOrientationMatches(orientation, in: app) else {
                attach("missing-" + name)
                app.terminate()
                continue
            }
            // NSLog goes directly to the live xcodebuild stream; one distinct marker per phase.
            NSLog("FARSIDE_EXTERNAL_PUBLIC_URL_READY %@ %@", phase, simulatorID)
            let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                prompt.exists && connect.exists && close.exists
            }, object: app)
            var reached = XCTWaiter().wait(for: [appeared], timeout: 30) == .completed
            if !reached {
                _ = missing("External farside://open did not present Connect question root and both actions within 30 seconds (\(phase))")
            } else if XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists
                        || visibleNavigationFrame(connect, in: app) == nil
                        || visibleNavigationFrame(close, in: app) == nil {
                reached = missing("External Connect question actions were covered or outside the visible viewport (\(phase))")
            }
            if !captureOrientationMatches(orientation, in: app) { reached = false }
            attach(reached ? name : "missing-" + name)
            NSLog("FARSIDE_EXTERNAL_PUBLIC_URL_FINISHED %@ %@", phase, simulatorID)
            app.terminate()
        }
        #else
        throw XCTSkip("External public URL capture is simulator-only")
        #endif
    }

    /// FARSIDE_ALL_ORIENTATIONS=1 repeats every base shot in portrait and landscape.
    /// FARSIDE_ACCESSIBILITY_SHOTS=1 selects eight key screens at AX-XXXL for a short pass.
    /// All runner variables use the TEST_RUNNER_ prefix when passed through xcodebuild.
    /// FARSIDE_SHOTS=controls,hold-finger still filters by base name (or landscape alias).
    @MainActor
    func testCaptureEveryScreen() {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        let only = environment["FARSIDE_SHOTS"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let allOrientations = environment["FARSIDE_ALL_ORIENTATIONS"] == "1"
        let accessibility = environment["FARSIDE_ACCESSIBILITY_SHOTS"] == "1"
        let keyScreens: Set<String> = ["home", "pairing-camera-priming", "anywhere-paywall", "coach-complete",
                                       "dock", "keyboard", "controls-settings", "picture"]
        // Attach the expected list before starting so interrupted or omitted captures are visible.
        var planned: [String] = []
        for shot in shots where only?.contains(shot.name) ?? true {
            if accessibility && !keyScreens.contains(shot.name) { continue }
            if allOrientations && shot.landscape && only == nil { continue }
            let variants = allOrientations && !shot.landscape ? [false, true] : [shot.landscape]
            for landscape in variants {
                let name = (accessibility ? "ax-xxxl-" : "")
                    + (landscape && !shot.landscape ? "landscape-" : "") + shot.name
                planned.append(name)
                if ["picture", "controls-settings-keyboard", "controls-settings-diagnostics", "controls-shortcuts-expanded"].contains(shot.name) {
                    planned.append(name + "-lower")
                }
            }
        }
        let plan = XCTAttachment(string: planned.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)
        for shot in shots where only?.contains(shot.name) ?? true {
            if accessibility && !keyScreens.contains(shot.name) { continue }
            if allOrientations && shot.landscape && only == nil { continue }
            let orientations: [UIDeviceOrientation] = allOrientations && !shot.landscape
                ? [.portrait, .landscapeLeft] : [shot.landscape ? .landscapeLeft : .portrait]
            for orientation in orientations {
                let name = (accessibility ? "ax-xxxl-" : "")
                    + (orientation == .landscapeLeft && !shot.landscape ? "landscape-" : "") + shot.name
                XCUIDevice.shared.orientation = orientation
                // These preferences affect fixture appearance. Keep every launch deterministic;
                // launch-domain overrides expire with this simulator process.
                app.launchArguments = shot.arguments + ["-disableBigTextAutoLevel", "YES"]
                // Big Text's request/acknowledgment must be allowed to read its own saved choice
                // when a fixture has a pairing. Its navigation resets Off explicitly instead.
                if !["big-text-pending", "big-text-selected"].contains(shot.name) {
                    app.launchArguments += ["-bigTextByMac", "{}"]
                }
                if accessibility {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                }
                app.launch()
                var reached = prepare(shot, in: app)
                if reached && shot.name != "big-text-pending" {
                    Thread.sleep(forTimeInterval: min(shot.wait, 0.6))
                }
                if reached && shot.name == "pairing-scanning" {
                    // Scanner authorization/configuration is asynchronous; a transient viewfinder
                    // must not label a later unavailable state or system question as scanning.
                    let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    let viewfinder = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Camera viewfinder")).firstMatch
                    reached = !app.staticTexts["No camera here"].exists
                        && !app.staticTexts["Camera is off for Farside"].exists
                        && !system.alerts.firstMatch.exists && viewfinder.exists
                    if !reached { _ = missing("Camera viewfinder changed to fallback or permission prompt before capture") }
                }
                if !captureOrientationMatches(orientation, in: app) { reached = false }
                attach(reached ? name : "missing-" + name)
                // Long settings forms need both their top and lower rows in the catalogue.
                if reached && ["picture", "controls-settings-keyboard", "controls-settings-diagnostics", "controls-shortcuts-expanded"].contains(shot.name) {
                    let page = element("remote.controls.page", in: app)
                    if page.exists {
                        page.swipeUp()
                        page.swipeUp()
                        attach(name + "-lower")
                    }
                }
                app.terminate()
            }
        }
    }

    @MainActor
    private func prepare(_ shot: Shot, in app: XCUIApplication) -> Bool {
        // Privacy recovery must be an explicit user action even in the offline test fixture.
        if shot.arguments.contains("--ui-layout-check") && shot.name != "concealed" {
            let recovered = app.buttons["Return to Farside"]
            if recovered.exists && recovered.isHittable { recovered.tap() }
        }
        switch shot.name {
        case "home-help-menu":
            let help = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Help and more")).firstMatch
            let details = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Connection Details")).firstMatch
            return tap(help, in: app) && require(details, "Home help menu")
        case "home-connection-details", "home-legal", "home-security", "home-server-data", "home-server-data-confirm", "home-forget-confirm", "home-paired-macs":
            let choices = ["home-connection-details": "Connection Details", "home-legal": "Third-Party Notices",
                           "home-security": "Settings", "home-server-data": "Server Data", "home-server-data-confirm": "Server Data",
                           "home-forget-confirm": "Forget This Mac", "home-paired-macs": "Your Macs"]
            let choice = choices[shot.name]!
            let captureOrientation = XCUIDevice.shared.orientation
            let portraitNavigation = ["Settings", "Forget This Mac"].contains(choice)
                && (captureOrientation == .landscapeLeft || captureOrientation == .landscapeRight)
            // Native menus clip these bottom rows in short landscape. Open the destination in
            // portrait, then verify and capture its actual landscape layout. The menu shot itself
            // still opens in the requested orientation and preserves the clipped-menu evidence.
            if portraitNavigation { XCUIDevice.shared.orientation = .portrait }
            defer {
                if portraitNavigation && XCUIDevice.shared.orientation != captureOrientation {
                    XCUIDevice.shared.orientation = captureOrientation
                }
            }
            let help = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Help and more")).firstMatch
            guard tap(help, in: app) else { return false }
            let target = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", choice))
            // SwiftUI menu rows may be Button or PopUpButton. Short landscape menus scroll;
            // drag a visible menu row rather than the Home scroll view behind the popover.
            let menuLabels = ["Your Macs", "How to steer", "Trouble connecting?", "Paste Pairing Code",
                              "Connection Details", "Farside Anywhere", "Third-Party Notices", "Server Data", "Settings", "Forget This Mac"]
            let menuRows = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", menuLabels))
            var opened = false
            for attempt in 0..<5 {
                _ = target.firstMatch.waitForExistence(timeout: attempt == 0 ? 1 : 0.3)
                if let visibleTarget = target.allElementsBoundByIndex.last(where: { visibleNavigationFrame($0, in: app) != nil && $0.isHittable }) {
                    visibleTarget.tap()
                    opened = true
                    break
                }
                guard let visibleRow = menuRows.allElementsBoundByIndex.last(where: { visibleNavigationFrame($0, in: app) != nil && $0.isHittable }) else { break }
                visibleRow.swipeUp()
            }
            guard opened else { return missing("Home menu item unavailable or covered: \(choice)") }
            if portraitNavigation { XCUIDevice.shared.orientation = captureOrientation }
            if shot.name == "home-server-data-confirm" {
                return tap(app.buttons["privacy.removeDevice"], in: app)
                    && require(app.buttons["Remove Device Link"], "Server removal confirmation")
            }
            if shot.name == "home-forget-confirm" {
                return require(app.buttons["Forget Mac"], "Local forget confirmation")
            }
            if shot.name == "home-security" {
                return require(app.switches["settings.security.requireOwner"], "Security settings")
            }
            return require(app.navigationBars[choices[shot.name]!], choices[shot.name]!)
        case "home-session-check", "home-session-support", "home-session-blocker-options":
            // UsefulSessionEntry owns its sheet state inside Home's orientation-specific tree.
            // Keep that presenter alive by navigating in the requested capture orientation.
            guard tap(app.buttons["Session check"], in: app) else { return false }
            guard require(app.navigationBars["Session check"], "Useful-session progress") else { return false }
            if shot.name == "home-session-blocker-options" {
                let picker = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "What got in the way?")).firstMatch
                guard tap(picker, in: app) else { return false }
                return visibleOptions(["Reaching the Mac", "Seeing a usable picture", "Controlling the Mac",
                                       "Finishing my task", "Nothing; the task worked"], in: app)
            }
            return shot.name == "home-session-check" || reveal(app.buttons["Copy a safe support summary"], in: app)
        case "home-system-connect-prompt":
            #if targetEnvironment(simulator)
            // Ask the OS to open the existing public question route. The UI test runner may
            // refuse background URL opens; that is a bounded gap, never a fabricated prompt.
            let completion = XCTestExpectation(description: "System opened Farside public question URL")
            var opened = false
            defer { app.activate() }
            UIApplication.shared.open(URL(string: "farside://open")!, options: [:]) { accepted in
                opened = accepted
                completion.fulfill()
            }
            guard XCTWaiter().wait(for: [completion], timeout: 4) == .completed else {
                return missing("System public URL open completion timed out after four seconds")
            }
            guard opened else { return missing("System refused farside://open from the simulator UI test runner") }
            app.activate()
            // The route presents a question only; never tap the Connect action.
            return require(element("connectPrompt", in: app), "Public-route Connect question after accepted system URL open")
                && require(app.buttons["connectPrompt.connect"], "Connect question action")
                && require(app.buttons["connectPrompt.close"], "Connect question dismissal")
            #else
            return missing("Public URL catalogue navigation requires an iOS Simulator")
            #endif
        case "pairing-malformed-code":
            let field = app.textViews["Pairing code"].exists ? app.textViews["Pairing code"] : app.textFields["Pairing code"]
            guard tap(field, in: app) else { return false }
            // This deliberately invalid local string cannot identify a Mac or enroll a phone.
            field.typeText("not-a-farside-pairing-code")
            return tap(app.buttons["Pair Mac"], in: app) && require(element("pairing.feedback", in: app), "Malformed pairing feedback")
        case "pairing-camera-unavailable", "pairing-scanning":
            #if targetEnvironment(simulator)
            let captureOrientation = XCUIDevice.shared.orientation
            XCUIDevice.shared.orientation = .portrait
            defer {
                if XCUIDevice.shared.orientation != captureOrientation {
                    XCUIDevice.shared.orientation = captureOrientation
                }
            }
            guard tap(app.buttons["pairing.camera.continue"], in: app) else { return false }
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let alert = system.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) {
                for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                    XCUIDevice.shared.orientation = orientation
                    guard alert.waitForExistence(timeout: 2) else {
                        return missing("Camera permission alert disappeared during orientation capture")
                    }
                    let cameraText = alert.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS[c] %@", "camera")).firstMatch
                    guard cameraText.exists || alert.label.localizedCaseInsensitiveContains("camera") else {
                        return missing("Camera fixture interrupted by a different system alert")
                    }
                    let permissionName = (orientation == .portrait ? "portrait-" : "landscape-") + "system-camera-permission"
                    let deadline = Date().addingTimeInterval(3)
                    var matchesOrientation = false
                    repeat {
                        let frame = app.frame
                        matchesOrientation = orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
                        if matchesOrientation { break }
                        Thread.sleep(forTimeInterval: 0.25)
                    } while Date() < deadline
                    if matchesOrientation && alert.exists && (cameraText.exists || alert.label.localizedCaseInsensitiveContains("camera")) {
                        attach(permissionName)
                    } else {
                        _ = missing("Native camera permission did not retain its verified root in the requested orientation")
                        attach("missing-" + permissionName)
                    }
                }
                XCUIDevice.shared.orientation = .portrait
                guard alert.waitForExistence(timeout: 2) else { return missing("Camera permission alert did not return in portrait") }
                guard require(alert.buttons["Allow"], "Simulator camera permission Allow") else { return false }
                alert.buttons["Allow"].tap()
                guard alert.waitForNonExistence(timeout: 3) else { return missing("Simulator camera permission did not dismiss") }
            }
            XCUIDevice.shared.orientation = captureOrientation
            if shot.name == "pairing-camera-unavailable" {
                return require(app.staticTexts["No camera here"], "Simulator camera unavailable")
            }
            // Camera hardware is absent on some simulators. Never label its fallback as scanning.
            if app.staticTexts["No camera here"].exists { return missing("Simulator has no live camera scanner") }
            return require(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Camera viewfinder")).firstMatch,
                           "Camera scanning (simulator camera may be unavailable)")
            #else
            return missing("Camera permission catalogue actions require an iOS Simulator")
            #endif
        case "big-text-pending", "big-text-selected":
            // The Controls root requests the probe's display descriptors on appearance. Pushing
            // Picture directly at launch can skip that appearance and leave Big Text with no steps.
            guard require(element("remote.controls.content", in: app), "Controls for Big Text"),
                  tap(app.buttons["remote.controls.settings"].firstMatch, in: app),
                  tap(app.buttons["remote.settings.picture"].firstMatch, in: app),
                  require(app.navigationBars["Picture"], "Big Text picture settings") else { return false }
            let off = app.buttons["remote.bigText.off"]
            guard revealBigText(off, in: app) else { return false }
            if !off.isSelected {
                off.tap()
                guard selected(off) else { return false }
                _ = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch.waitForNonExistence(timeout: 3)
            }
            let step = app.buttons["remote.bigText.step.0"]
            guard revealBigText(step, in: app), tap(step, in: app, scroll: false) else { return false }
            let pill = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch
            if shot.name == "big-text-pending" {
                // Show the canvas pill rather than a progress element hidden behind Settings.
                let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
                    .allElementsBoundByIndex.first(where: { visibleNavigationFrame($0, in: app) != nil && $0.isHittable })
                guard let done else { return missing("Big Text settings dismissal is unavailable") }
                done.tap()
                return require(pill, "Big Text change in progress", timeout: 2)
            }
            guard require(pill, "Big Text request began", timeout: 2) else { return false }
            guard selected(step) else { return false }
            guard pill.waitForNonExistence(timeout: 3) else { return missing("Big Text confirmation did not clear progress") }
            return selected(step)
        case "controls-keyboard-view-options", "controls-precision-tap-options":
            let keyboard = shot.name == "controls-keyboard-view-options"
            guard require(app.navigationBars[keyboard ? "View" : "Touch"], "Local controls options page") else { return false }
            let picker = element(keyboard ? "remote.keyboardView" : "remote.precisionTap", in: app)
            guard revealLocalSettingsRow(picker, in: app), tap(picker, in: app, scroll: false) else { return false }
            // Exact, hittable choices distinguish the opened picker from descriptive footers.
            return visibleOptions(keyboard ? ["Pinned", "Follow typing"] : ["Off", "Touch and hold", "Every tap"], in: app)
        case "controls-shortcuts-expanded":
            guard require(app.navigationBars["Keyboard and pointer"], "Keyboard shortcuts page") else { return false }
            let disclosure = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Shortcuts")).firstMatch
            guard revealLocalSettingsRow(disclosure, in: app), tap(disclosure, in: app, scroll: false) else { return false }
            let shortcut = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                                      "App Switcher", "⌃⌥Tab", "⌘Tab")).firstMatch
            return revealLocalSettingsRow(shortcut, in: app)
        case "controls-lan-wake":
            guard tap(app.buttons["remote.controls.settings"].firstMatch, in: app) else { return false }
            guard tap(app.buttons["Wake another Mac on this LAN"], in: app) else { return false }
            return require(app.navigationBars["LAN wake"], "LAN wake helper")
        default: break
        }
        if shot.name == "home-alert-settings" { return require(element("agent.settings", in: app), "Alerts settings") }
        if shot.name.hasPrefix("agent-alert") { return require(element("agent.alert.sheet", in: app), "Agent alert") }
        if shot.name == "agent-banner" { return require(element("agent.alert.banner", in: app), "Agent banner") }
        if shot.name == "home-low-battery" { return require(element("home.vitals", in: app), "Last-seen Mac battery") }
        if shot.name == "pairing-success" {
            let label = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paired. Now choose Allow on your Mac.")).firstMatch
            return require(label, "Pairing success")
        }
        if shot.name == "pairing-camera-denied" { return require(app.staticTexts["Camera is off for Farside"], "Camera denied") }
        if shot.arguments.contains("--ui-pairing-expired") { return require(element("pairing.feedback", in: app), "Expired pairing feedback") }
        if shot.arguments.contains(where: { $0.hasPrefix("--ui-pairing-") }) { return require(element("pairing.sheet", in: app), "Pairing sheet") }
        if shot.arguments.contains("--ui-coach") { return require(element("coach", in: app), "Gesture coach") }
        if let primer = shot.arguments.first(where: { $0.hasPrefix("--ui-priming-") }) {
            let titles = ["--ui-priming-network": "Connect faster at home.", "--ui-priming-mic": "Two quick permissions.",
                          "--ui-priming-camera": "Point, then pair.", "--ui-priming-notifications": "Know when it needs you."]
            let heading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", titles[primer] ?? "")).firstMatch
            return require(heading, "Permission primer heading") && require(app.buttons["Continue"].firstMatch, "Permission primer")
        }
        if shot.arguments.contains(where: { $0.hasPrefix("--ui-error=") }) { return require(app.buttons["error.primary"], "Connection blocker") }
        if shot.arguments.contains("--ui-troubleshoot") { return require(app.buttons["Try again"], "Troubleshooting") }
        if shot.arguments.contains("--ui-paywall") { return require(element("anywhere.paywall", in: app), "Anywhere paywall") }
        if shot.name == "concealed" { return require(element("remote.concealed", in: app), "Concealed session") }
        if let pageArgument = shot.arguments.first(where: { $0.hasPrefix("--ui-controls-page=") }) {
            let page = String(pageArgument.dropFirst("--ui-controls-page=".count))
            let titles = ["picture": "Picture", "pointer": "Pointer", "display": "Display", "touch": "Touch", "view": "View",
                          "clipboard": "Clipboard", "keyboard": "Keyboard and pointer", "steer": "How to steer", "diagnostics": "Diagnostics"]
            guard require(app.navigationBars[titles[page] ?? page], "Controls page \(page)") else { return false }
            return true
        }
        if shot.arguments.contains("--ui-controls-settings") { return require(element("remote.controls.page", in: app), "Controls settings") }
        if shot.arguments.contains("--ui-controls-check") { return require(element("remote.controls.content", in: app), "Controls") }
        if shot.arguments.contains("--ui-keyboard-check") { return require(app.buttons["remote.keyboard.hide"], "Keyboard") }
        if shot.arguments.contains("--ui-voice-preview-check") { return require(element("remote.voice", in: app), "Dictation") }
        if shot.arguments.contains("--ui-clipboard-row") { return require(element("remote.clipboard.row", in: app), "Clip and Files row") }
        if shot.arguments.contains("--ui-data-warning") { return require(element("remote.dataWarning", in: app), "Data warning") }
        if shot.arguments.contains("--ui-reconnecting") { return require(element("remote.reconnecting", in: app), "Reconnecting session") }
        if shot.arguments.contains("--ui-issue-sharing") { return require(element("remote.issue.screenSharingOff", in: app), "Sharing-stopped session") }
        if shot.arguments.contains(where: { $0.hasPrefix("--ui-hold-preview=") }) { return require(element("remote.holdChip", in: app), "Held click") }
        if shot.arguments.contains("--ui-couch") { return require(app.buttons["remote.couch.controls"], "Couch trackpad") }
        if shot.arguments.contains("--ui-dock-open") { return require(element("remote.dock", in: app), "Session dock") }
        if shot.arguments.contains("--ui-layout-check") { return require(element("remote.canvas", in: app), "Session canvas") }
        return require(element("phone.home", in: app), "Home")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func require(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 4) -> Bool {
        element.waitForExistence(timeout: timeout) || missing("Missing \(description)")
    }

    @MainActor
    private func visibleOptions(_ labels: [String], in app: XCUIApplication) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            let allVisible = labels.allSatisfy { label in
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                    .allElementsBoundByIndex.contains { visibleNavigationFrame($0, in: app) != nil && $0.isHittable }
            }
            if allVisible { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return missing("Opened local picker did not present all visible choices: " + labels.joined(separator: ", "))
    }

    @MainActor
    private func revealLocalSettingsRow(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let page = element("remote.controls.page", in: app)
        guard require(page, "Local options settings scroll page") else { return false }
        // Short landscape forms can fling past a disclosure or picker on a full swipe.
        for _ in 0..<20 {
            if visibleNavigationFrame(target, in: app) != nil && target.isHittable { return true }
            let frame = page.frame
            guard frame.height > 0 else { return missing("Local options page has no usable scroll area") }
            let passedTarget = target.exists && target.frame.maxY <= frame.minY
            let distance = min(120, max(44, frame.height * 0.18))
            let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: passedTarget ? 0.32 : 0.72))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: passedTarget ? distance : -distance)))
        }
        return (visibleNavigationFrame(target, in: app) != nil && target.isHittable) || missing("Local option or expanded shortcut row unavailable after bounded short scrolling")
    }

    @MainActor
    private func revealBigText(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let page = element("remote.controls.page", in: app)
        guard require(page, "Big Text settings scroll page") else { return false }
        for _ in 0..<20 {
            if visibleNavigationFrame(target, in: app) != nil && target.isHittable { return true }
            let frame = page.frame
            guard frame.height > 0 else { return missing("Big Text settings page has no usable scroll area") }
            let passedTarget: Bool
            if target.exists {
                passedTarget = target.frame.maxY <= frame.minY
            } else {
                let laterSection = app.staticTexts["Smooth motion"].firstMatch
                passedTarget = visibleNavigationFrame(laterSection, in: app) != nil && laterSection.isHittable
            }
            // A full swipe can fling the short landscape form past the whole Big Text section.
            // Short press-drags advance a small part of the viewport, checking after each move.
            let distance = min(120, max(44, frame.height * 0.18))
            let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: passedTarget ? 0.32 : 0.72))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: passedTarget ? distance : -distance)))
        }
        return (visibleNavigationFrame(target, in: app) != nil && target.isHittable) || missing("Big Text option unavailable after bounded short scrolling")
    }

    @MainActor
    private func visibleNavigationFrame(_ target: XCUIElement, in app: XCUIApplication) -> CGRect? {
        guard target.exists else { return nil }
        let frame = target.frame
        let appFrame = app.frame
        guard [frame.minX, frame.minY, frame.width, frame.height,
               appFrame.minX, appFrame.minY, appFrame.width, appFrame.height].allSatisfy({ $0.isFinite }),
              frame.width > 0, frame.height > 0, appFrame.width > 0, appFrame.height > 0,
              appFrame.contains(frame) else { return nil }
        let scopes = [element("remote.controls.page", in: app), app.scrollViews["phone.home"].firstMatch]
        for scope in scopes where scope.exists {
            // Home's landscape column and settings Forms clip within the app frame.
            // Match the same framed descendant so unrelated sheet/menu controls stay independent.
            let inScope = scope.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", target.label)).allElementsBoundByIndex
                .contains { $0.exists && $0.frame == frame }
            if inScope && !scope.frame.intersection(appFrame).contains(frame) { return nil }
        }
        return frame
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if visibleNavigationFrame(target, in: app) != nil { return true }
            let page = element("remote.controls.page", in: app)
            let home = app.scrollViews["phone.home"].firstMatch
            let scroll: XCUIElement?
            let isHome: Bool
            if page.exists { scroll = page; isHome = false }
            else if app.tables.firstMatch.exists { scroll = app.tables.firstMatch; isHome = false }
            else if app.collectionViews.firstMatch.exists { scroll = app.collectionViews.firstMatch; isHome = false }
            else if home.exists { scroll = home; isHome = true }
            else { scroll = nil; isHome = false }
            let appFrame = app.frame
            guard [appFrame.minX, appFrame.minY, appFrame.width, appFrame.height].allSatisfy({ $0.isFinite }),
                  appFrame.width > 0, appFrame.height > 0 else {
                return missing("Navigation app anchor has no finite visible frame")
            }
            let viewport = scroll.map { $0.frame.intersection(appFrame) } ?? appFrame
            guard [viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy({ $0.isFinite }),
                  viewport.width > 0, viewport.height > 0 else {
                return missing("Navigation scroll viewport has no finite visible frame")
            }
            let scrollDown = target.exists && target.frame.minY < viewport.minY
            // Full landscape Home swipes can fling Session check entirely above its column.
            // Use short scoped drags there, and reverse when the target has passed the top.
            let distance = isHome ? min(100, viewport.height * 0.22) : viewport.height * 0.6
            let startPoint = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * (scrollDown ? 0.25 : 0.75))
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: startPoint.x - appFrame.minX, dy: startPoint.y - appFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: scrollDown ? distance : -distance)))
        }
        return visibleNavigationFrame(target, in: app) != nil || missing("Cannot reveal requested navigation control inside its visible viewport")
    }

    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication, scroll: Bool = true) -> Bool {
        if scroll {
            if !target.waitForExistence(timeout: 1) || visibleNavigationFrame(target, in: app) == nil {
                guard reveal(target, in: app) else { return false }
            }
        } else if !target.waitForExistence(timeout: 3) {
            return missing("Requested navigation control is unavailable")
        }
        guard let frame = visibleNavigationFrame(target, in: app) else {
            return missing("Requested navigation control is outside the visible viewport")
        }
        // isHittable can raise an XCTest exception for clipped SwiftUI activation points.
        // Tap the verified visible rect through the app anchor; callers still require the exact
        // destination root before accepting its screenshot, so a covered control is never proof.
        let appFrame = app.frame
        guard [appFrame.minX, appFrame.minY, appFrame.width, appFrame.height].allSatisfy({ $0.isFinite }),
              appFrame.width > 0, appFrame.height > 0, appFrame.contains(frame) else {
            return missing("Navigation app anchor changed before coordinate tap")
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)).tap()
        return true
    }

    @MainActor
    private func captureOrientationMatches(_ requested: UIDeviceOrientation, in app: XCUIApplication) -> Bool {
        let landscape = requested == .landscapeLeft || requested == .landscapeRight
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var frame = app.frame
        while true {
            if landscape ? frame.width > frame.height : frame.height > frame.width { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            Thread.sleep(forTimeInterval: 0.1)
            frame = app.frame
        }
        return missing("Requested \(landscape ? "landscape" : "portrait") capture does not match observed Farside app frame \(frame.width) × \(frame.height)")
    }

    @MainActor
    private func selected(_ target: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: target)
        return XCTWaiter().wait(for: [expectation], timeout: 4) == .completed || missing("Big Text selection was not confirmed")
    }

    private func missing(_ message: String) -> Bool {
        XCTFail(message)
        let diagnostic = XCTAttachment(string: message)
        diagnostic.name = "missing-state-reason"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        return false
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
