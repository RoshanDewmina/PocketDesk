import XCTest

/// The automation pre-flight that script/physical/run.sh runs before any other physical test, so a locked
/// iPhone or a missing UI-automation authorization fails within seconds instead of stalling a feature test.
/// It presses Home on the iPhone and reads the Home Screen. It does not launch Farside or reach the Mac.
final class PhysicalPreflightTests: XCTestCase {
    @MainActor
    func testAutomationReady() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_PREFLIGHT"] == "1" else {
            throw XCTSkip("Run by script/physical/run.sh as its automation pre-flight")
        }
        continueAfterFailure = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10), "The Home Screen must come to the front")
        let icon = springboard.icons.firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "UI automation must read Home Screen icons; the lock screen has none")
        XCTAssertTrue(icon.isHittable, "The Home Screen, not the lock screen, must be in front")
    }
}
