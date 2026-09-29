#if os(macOS)
import CoreGraphics
import XCTest

/// Which windows the E2E harness treats as covering the Test Pad. System containers that span the
/// display must not block every click; alerts, crash reports and other apps' windows must.
final class E2EWindowCoverTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let pad = CGRect(x: 40, y: 420, width: 700, height: 500)
    private let padPID: Int32 = 900

    private func window(_ owner: String, pid: Int32 = 100, layer: CGWindowLevelKey? = nil, rawLayer: Int = 0,
                        alpha: Double = 1, bounds: CGRect) -> E2EWindowCover.Window {
        E2EWindowCover.Window(owner: owner, pid: pid, layer: layer.map { Int(CGWindowLevelForKey($0)) } ?? rawLayer,
                              alpha: alpha, bounds: bounds)
    }

    func testFullScreenSystemContainersAreBackdrops() {
        for (owner, level) in [("Dock", CGWindowLevelKey.dockWindow), ("Notification Center", .dockWindow),
                               ("Screenshot", .mainMenuWindow)] {
            XCTAssertTrue(E2EWindowCover.isBackdrop(window(owner, layer: level, bounds: display), display: display), owner)
        }
        XCTAssertTrue(E2EWindowCover.isBackdrop(window("Cursor", layer: .cursorWindow, bounds: CGRect(x: 300, y: 600, width: 32, height: 32)),
                                                display: display))
        XCTAssertTrue(E2EWindowCover.isBackdrop(window("Window Server", layer: .mainMenuWindow, bounds: CGRect(x: 0, y: 0, width: 1512, height: 37)),
                                                display: display))
        XCTAssertTrue(E2EWindowCover.isBackdrop(window("Invisible", alpha: 0, bounds: pad), display: display))
    }

    func testAlertsCrashReportsAndAppWindowsAreObstructions() {
        let dialog = CGRect(x: 200, y: 500, width: 420, height: 180)
        XCTAssertFalse(E2EWindowCover.isBackdrop(window("UserNotificationCenter", rawLayer: 8, bounds: dialog), display: display))
        XCTAssertFalse(E2EWindowCover.isBackdrop(window("Problem Reporter", bounds: dialog), display: display))
        XCTAssertFalse(E2EWindowCover.isBackdrop(window("CoreServicesUIAgent", rawLayer: 8, bounds: dialog), display: display))
        XCTAssertFalse(E2EWindowCover.isBackdrop(window("System Settings", bounds: dialog), display: display))
        // A normal app window that happens to fill the screen is still an app window.
        XCTAssertFalse(E2EWindowCover.isBackdrop(window("Safari", bounds: display), display: display))
        // A notification banner is not a full-screen container, so it counts even at the Dock's level.
        let banner = window("NotificationCenter", layer: .dockWindow, bounds: CGRect(x: 1150, y: 40, width: 350, height: 90))
        XCTAssertFalse(E2EWindowCover.isBackdrop(banner, display: display))
    }

    func testTopmostSkipsBackdropsAndFindsTheRealWindowUnderThePointer() {
        let point = CGPoint(x: 300, y: 600)
        let windows = [window("Cursor", layer: .cursorWindow, bounds: CGRect(x: 290, y: 590, width: 32, height: 32)),
                       window("Dock", layer: .dockWindow, bounds: display),
                       window("Farside Test Pad", pid: padPID, bounds: pad),
                       window("Finder", bounds: display)]
        XCTAssertEqual(E2EWindowCover.topmost(at: point, in: windows, display: display)?.owner, "Farside Test Pad")
        let blocked = [window("UserNotificationCenter", rawLayer: 8, bounds: CGRect(x: 200, y: 500, width: 420, height: 180))] + windows
        XCTAssertEqual(E2EWindowCover.topmost(at: point, in: blocked, display: display)?.owner, "UserNotificationCenter")
    }

    func testCoveringListsOnlyOtherOwnersThatOverlapTheTestPad() {
        let windows = [window("Dock", layer: .dockWindow, bounds: display),
                       window("Farside Test Pad", pid: padPID, bounds: pad),
                       window("Problem Reporter", pid: 7, bounds: CGRect(x: 500, y: 700, width: 400, height: 300)),
                       window("Problem Reporter", pid: 7, bounds: CGRect(x: 520, y: 720, width: 400, height: 300)),
                       window("Notes", pid: 8, bounds: CGRect(x: 900, y: 100, width: 400, height: 300)),
                       window("Edge", pid: 9, bounds: CGRect(x: 739, y: 420, width: 200, height: 200))]
        XCTAssertEqual(E2EWindowCover.covering(pad, windows: windows, ownPID: padPID, display: display), ["Problem Reporter"])
    }
}
#endif
