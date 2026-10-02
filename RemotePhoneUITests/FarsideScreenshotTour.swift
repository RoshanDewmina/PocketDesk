import XCTest

/// Screenshots of every redesigned screen, attached to the test result. Skipped unless the
/// runner is started with `TEST_RUNNER_FARSIDE_SCREENSHOTS=1`, so ordinary runs stay fast.
final class FarsideScreenshotTour: XCTestCase {
    private struct Shot {
        let name: String
        let arguments: [String]
        var landscape = false
        var wait: TimeInterval = 2.5
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
        for shot in shots where only?.contains(shot.name) ?? true {
            XCUIDevice.shared.orientation = shot.landscape ? .landscapeLeft : .portrait
            app.launchArguments = shot.arguments
            app.launch()
            Thread.sleep(forTimeInterval: shot.wait)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = shot.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
