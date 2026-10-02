import XCTest

/// Screenshots of every redesigned screen, attached to the test result. Skipped unless the
/// runner is started with `TEST_RUNNER_FARSIDE_SCREENSHOTS=1`, so ordinary runs stay fast.
final class FarsideScreenshotTour: XCTestCase {
    private struct Shot {
        let name: String
        let arguments: [String]
        var landscape = false
        var wait: TimeInterval = 2.5
        var scrollToEnd = false
    }

    /// Full-screen iPad captures remain separate from the original phone parity shot names.
    /// No width override is used here: these are actual portrait/landscape simulator windows.
    private var iPadShots: [Shot] {
        let states: [(String, [String])] = [
            ("home-empty", ["--ui-x"]),
            ("home", ["--ui-demo-mac", "--ui-last-reached"]),
            ("pairing-camera-priming", ["--ui-pairing-scan", "--ui-camera-priming"]),
            ("pairing-steps", ["--ui-pairing-scan", "--ui-camera-priming"]),
            ("anywhere-paywall", ["--ui-paywall"]),
            ("controls-settings", ["--ui-layout-check", "--ui-controls-settings"]),
            ("session-fit", ["--ui-layout-check", "--ui-viewport-fit", "--ui-pointer-preview"]),
            ("session-fill", ["--ui-layout-check", "--ui-viewport-fill", "--ui-pointer-preview"]),
            ("dock", ["--ui-layout-check", "--ui-viewport-fit", "--ui-dock-open"]),
            ("controls", ["--ui-layout-check", "--ui-viewport-fit", "--ui-controls-check"]),
            ("keyboard", ["--ui-layout-check", "--ui-viewport-fit", "--ui-keyboard-check", "--ui-software-keyboard"]),
            ("hardware-keyboard-field", ["--ui-layout-check", "--ui-viewport-fit", "--ui-keyboard-check", "--ui-hardware-keyboard"]),
            ("couch", ["--ui-layout-check", "--ui-couch", "--ui-demo-mac"]),
            ("reconnecting", ["--ui-layout-check", "--ui-reconnecting"]),
            ("mac-busy", ["--ui-layout-check", "--ui-mac-busy"]),
            ("big-text-changing", ["--ui-layout-check", "--ui-big-text-changing"])
        ]
        return [false, true].flatMap { landscape in
            states.map { name, arguments in
                Shot(name: "ipad-\(landscape ? "landscape" : "portrait")-\(name)",
                     arguments: arguments, landscape: landscape, wait: 4, scrollToEnd: name == "pairing-steps")
            }
        }
    }

    /// DEBUG-constrained app content, not real system Split View or Stage Manager.
    /// The outer simulator window remains visible in every attachment. Explicit width classes
    /// keep these fixtures faithful to the design spec even on a different simulator model.
    private var syntheticWindowShots: [Shot] {
        let bands: [(String, Int, Int, String)] = [
            ("mini-portrait", 744, 1133, "regular"),
            ("mini-landscape", 1133, 744, "regular"),
            ("air11-portrait", 820, 1180, "regular"),
            ("air11-landscape", 1180, 820, "regular"),
            ("pro11-portrait", 834, 1210, "regular"),
            ("pro11-landscape", 1210, 834, "regular"),
            ("pro13-portrait", 1032, 1376, "regular"),
            ("pro13-landscape", 1376, 1032, "regular"),
            ("split-half11", 507, 834, "compact"),
            ("split-half11-wide", 600, 834, "compact"),
            ("split-half13", 683, 1032, "regular"),
            ("split-third", 320, 834, "compact"),
            ("slide-over", 400, 834, "compact"),
            ("split-portrait-two-thirds", 556, 1180, "compact"),
            ("split-portrait-third", 278, 1180, "compact"),
            ("split-two-thirds11", 680, 834, "regular"),
            ("split-two-thirds13", 900, 1032, "regular"),
            ("stage-manager-tall", 690, 1032, "regular"),
            ("stage-manager-wide", 900, 700, "regular")
        ]
        return bands.flatMap { name, width, height, widthClass in
            let window = ["--ui-window-width=\(width)", "--ui-window-height=\(height)",
                          "--ui-width-class=\(widthClass)"]
            return [
                Shot(name: "debug-\(name)-home", arguments: ["--ui-demo-mac", "--ui-last-reached"] + window,
                     landscape: width > height),
                Shot(name: "debug-\(name)-session", arguments: ["--ui-layout-check", "--ui-viewport-fit"] + window,
                     landscape: width > height)
            ]
        }
    }

    private let shots: [Shot] = [
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
        Shot(name: "controls", arguments: ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-curtain-preview",
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

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_FARSIDE_SCREENSHOTS=1 to capture the screenshot tour")
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// `TEST_RUNNER_FARSIDE_SHOTS=controls,hold-finger` captures only the named shots.
    @MainActor
    func testCaptureEveryScreen() {
        let app = XCUIApplication()
        let only = ProcessInfo.processInfo.environment["FARSIDE_SHOTS"].map { Set($0.split(separator: ",").map(String.init)) }
        let iPad = UIDevice.current.userInterfaceIdiom == .pad
        let available = shots + (iPad ? iPadShots + syntheticWindowShots : [])
        if let only {
            let unknown = only.subtracting(Set(available.map(\.name)))
            XCTAssertTrue(unknown.isEmpty, "Unknown screenshot names: \(unknown.sorted())")
        }
        // Optional one-band runs use the same launch contract as the named DEBUG matrix.
        let environment = ProcessInfo.processInfo.environment
        let windowOverrides = [("FARSIDE_WINDOW_WIDTH", "--ui-window-width="),
                               ("FARSIDE_WINDOW_HEIGHT", "--ui-window-height="),
                               ("FARSIDE_WINDOW_CLASS", "--ui-width-class=")]
            .compactMap { key, prefix in environment[key].map { prefix + $0 } }
        for shot in available where only?.contains(shot.name) ?? true {
            XCUIDevice.shared.orientation = shot.landscape ? .landscapeLeft : .portrait
            app.launchArguments = shot.arguments + windowOverrides
            app.launch()
            if (shot.name.hasPrefix("ipad-") || shot.name.hasPrefix("debug-")) && shot.arguments.contains("--ui-layout-check") {
                // The fixture can inherit explicit privacy recovery from an earlier background.
                // Keep the original phone tour launch path unchanged for exact parity captures.
                let recovery = app.buttons["Return to Farside"]
                if recovery.waitForExistence(timeout: 1) { recovery.tap() }
            }
            Thread.sleep(forTimeInterval: shot.wait)
            if shot.scrollToEnd { app.scrollViews.firstMatch.swipeUp() }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = shot.name
            attachment.lifetime = .keepAlways
            add(attachment)
            if shot.name.hasPrefix("ipad-") || shot.name.hasPrefix("debug-") {
                func rectangle(_ frame: CGRect) -> [String: Double] {
                    ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
                }
                var geometry: [String: Any] = ["shot": shot.name, "arguments": app.launchArguments,
                                               "synthetic": shot.name.hasPrefix("debug-"),
                                               "outer_window": rectangle(app.windows.firstMatch.frame)]
                for identifier in ["phone.home", "remote.canvas", "remote.picture", "remote.stacked.pad",
                                   "remote.session.pill", "remote.dock", "remote.controls.content"] {
                    let element = app.descendants(matching: .any)[identifier].firstMatch
                    if element.exists { geometry[identifier] = rectangle(element.frame) }
                }
                if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    let details = XCTAttachment(string: text)
                    details.name = shot.name + "-geometry"
                    details.lifetime = .keepAlways
                    add(details)
                }
            }
            app.terminate()
        }
    }
}
