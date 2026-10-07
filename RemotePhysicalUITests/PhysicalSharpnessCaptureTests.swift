import XCTest

/// Captures what the phone actually shows of a still Mac text chart, for a blind sharpness comparison
/// between host output sizes. Phone-side only: no remote click, typing or Mac-side change.
final class PhysicalSharpnessCaptureTests: XCTestCase {
    @MainActor
    func testCaptureStillChartInFit() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_PHYSICAL_SHARPNESS"] == "1" else {
            throw XCTSkip("Requires an explicit sharpness round with a ready paired Mac")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not a physical sharpness round")
        #else
        continueAfterFailure = false
        let label = environment["FARSIDE_SHARPNESS_LABEL"] ?? "round"
        let app = XCUIApplication()
        app.launchArguments = ["-viewportMode", "fit"]
        app.launch()
        let connect = app.buttons["home.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "Preserve the existing pairing")
        connect.tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 30), "Session must start")
        // A still screen keeps refining after the first frames; give it time before capturing.
        Thread.sleep(forTimeInterval: TimeInterval(environment["FARSIDE_SHARPNESS_SETTLE"] ?? "") ?? 8)
        for index in 1...3 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(label) still \(index)"
            shot.lifetime = .keepAlways
            add(shot)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(app.buttons["home.connect"].exists, "Session must survive the capture")
        app.terminate()
        #endif
    }
}
