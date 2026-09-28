import XCTest
import SwiftUI
@testable import PocketDeskRemote

@MainActor
final class SessionLifecycleTests: XCTestCase {
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
