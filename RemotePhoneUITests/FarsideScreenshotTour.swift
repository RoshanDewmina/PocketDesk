import XCTest

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
                if ["picture", "controls-settings-keyboard", "controls-settings-diagnostics"].contains(shot.name) {
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
                attach(reached ? name : "missing-" + name)
                // Long settings forms need both their top and lower rows in the catalogue.
                if reached && ["picture", "controls-settings-keyboard", "controls-settings-diagnostics"].contains(shot.name) {
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
                if let visibleTarget = target.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                    visibleTarget.tap()
                    opened = true
                    break
                }
                guard let visibleRow = menuRows.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) else { break }
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
        case "home-session-check", "home-session-support":
            let captureOrientation = XCUIDevice.shared.orientation
            let portraitNavigation = captureOrientation == .landscapeLeft || captureOrientation == .landscapeRight
            if portraitNavigation { XCUIDevice.shared.orientation = .portrait }
            defer {
                if portraitNavigation && XCUIDevice.shared.orientation != captureOrientation {
                    XCUIDevice.shared.orientation = captureOrientation
                }
            }
            guard tap(app.buttons["Session check"], in: app) else { return false }
            if portraitNavigation { XCUIDevice.shared.orientation = captureOrientation }
            guard require(app.navigationBars["Session check"], "Useful-session progress") else { return false }
            return shot.name == "home-session-check" || reveal(app.buttons["Copy a safe support summary"], in: app)
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
                    attach((orientation == .portrait ? "portrait-" : "landscape-") + "system-camera-permission")
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
            guard reveal(off, in: app) else { return false }
            if !off.isSelected {
                off.tap()
                guard selected(off) else { return false }
                _ = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch.waitForNonExistence(timeout: 3)
            }
            let step = app.buttons["remote.bigText.step.0"]
            guard tap(step, in: app) else { return false }
            let pill = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch
            if shot.name == "big-text-pending" {
                // Show the canvas pill rather than a progress element hidden behind Settings.
                let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
                    .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
                guard let done else { return missing("Big Text settings dismissal is unavailable") }
                done.tap()
                return require(pill, "Big Text change in progress", timeout: 2)
            }
            guard require(pill, "Big Text request began", timeout: 2) else { return false }
            guard selected(step) else { return false }
            guard pill.waitForNonExistence(timeout: 3) else { return missing("Big Text confirmation did not clear progress") }
            return selected(step)
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
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if target.exists && target.isHittable { return true }
            let page = element("remote.controls.page", in: app)
            if page.exists { page.swipeUp() }
            else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
            else if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        return target.exists && target.isHittable || missing("Cannot reveal requested navigation control")
    }

    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication, scroll: Bool = true) -> Bool {
        if scroll {
            if !target.waitForExistence(timeout: 1) || !target.isHittable {
                guard reveal(target, in: app) else { return false }
            }
        } else if !target.waitForExistence(timeout: 3) {
            return missing("Requested navigation control is unavailable")
        }
        guard target.isHittable else { return missing("Navigation control is covered: \(target.identifier)") }
        target.tap()
        return true
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
