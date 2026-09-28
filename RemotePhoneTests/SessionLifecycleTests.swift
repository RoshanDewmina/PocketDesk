import XCTest
import SwiftUI
import Combine
@testable import PocketDeskRemote

@MainActor
final class SessionLifecycleTests: XCTestCase {
    func testPointerFollowAcceptsValidRoundTripBeyondEightyMillisecondsAndStopsOnLift() {
        let locator = PointerLocator()
        var followed: [CGPoint] = []
        let subscription = locator.followUpdates.sink { followed.append($0) }
        defer { subscription.cancel() }

        locator.moved(at: 10)
        let probe = try! XCTUnwrap(locator.poll(at: 10.05, available: true))
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: probe,
                                     pointerLocation: PointerLocation(x: 900, y: 600)),
                        at: 10.24, sourceSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(followed, [CGPoint(x: 900, y: 600)], "A valid 190 ms reply should still follow")

        locator.moved(at: 11)
        let lateProbe = try! XCTUnwrap(locator.poll(at: 11.01, available: true))
        locator.stopFollowing()
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: lateProbe,
                                     pointerLocation: PointerLocation(x: 950, y: 620)),
                        at: 11.18, sourceSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(followed.count, 1, "A lifted finger must not retarget the viewport")
    }

    func testPointerFollowKeepsZoomedTargetAboveOpenDock() {
        var viewport = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                         canvasSize: CGSize(width: 390, height: 844), mode: .fill,
                                         zoom: 1.6, safeInsets: ViewportInsets(top: 50, bottom: 34))
        let canvas = CGRect(x: 0, y: 100, width: 390, height: 844)
        let dock = CGRect(x: 12, y: 760, width: 366, height: 184)
        let usable = PointerFollowLayout.usableRect(safeRect: viewport.safeRect,
                                                   canvasFrame: canvas, dockFrame: dock)
        XCTAssertEqual(usable.maxY, 648, accuracy: 0.001)
        let point = CGPoint(x: 720, y: 800)
        XCTAssertTrue(viewport.reveal(sourcePoint: point, in: usable))
        XCTAssertLessThanOrEqual(viewport.viewPoint(fromSource: point).y, usable.maxY - 32 + 0.001)
    }

    func testInactiveInterruptionsShieldThePictureButKeepTheSession() {
        let model = PhoneRemoteModel()
        model.sceneChanged(.active)
        let statusBefore = model.connection.status
        let inputRevisionBefore = model.inputRevision

        model.sceneChanged(.inactive)
        XCTAssertTrue(model.privacyShield, "Control Center or a call banner hides the picture")
        XCTAssertGreaterThan(model.inputRevision, inputRevisionBefore, "Interrupted touches and held input must be cancelled")
        XCTAssertFalse(model.contentConcealed, "An inactive scene must not end the session")
        XCTAssertEqual(model.connection.status, statusBefore, "An inactive scene must not disconnect")

        model.sceneChanged(.active)
        XCTAssertFalse(model.privacyShield, "Returning from Control Center restores the picture")
        XCTAssertFalse(model.contentConcealed)
        XCTAssertEqual(model.connection.status, statusBefore)
    }

    func testBackgroundEndsTheSessionAndKeepsTheScreenHidden() {
        let model = PhoneRemoteModel()
        model.sceneChanged(.active)
        model.sceneChanged(.inactive)
        model.sceneChanged(.background)
        XCTAssertTrue(model.contentConcealed)
        XCTAssertFalse(model.privacyShield)
        XCTAssertEqual(model.connection.status, "Disconnected")

        model.sceneChanged(.active)
        XCTAssertTrue(model.contentConcealed, "Returning from the background needs an explicit choice")
        model.dismissConcealment()
        XCTAssertFalse(model.contentConcealed)
    }

    func testLaunchTransitionsBeforeFirstActivationDoNothing() {
        let model = PhoneRemoteModel()
        model.sceneChanged(.inactive)
        XCTAssertFalse(model.privacyShield)
        model.sceneChanged(.background)
        XCTAssertFalse(model.contentConcealed)
    }
}

final class ViewportPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ViewportPreferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsToFillAndRemembersTheLastChoice() {
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
        ViewportPreference.store(.fit, in: defaults)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fit)
        ViewportPreference.store(.fit.toggled, in: defaults)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
    }

    func testUnknownStoredValueFallsBackToFill() {
        defaults.set("stretch", forKey: ViewportPreference.key)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
    }
}
