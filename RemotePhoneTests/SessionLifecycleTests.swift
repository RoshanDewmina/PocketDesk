import XCTest
import SwiftUI
import Combine
@testable import PocketDeskRemote

@MainActor
final class FakeBackgroundExecution: BackgroundExecution {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var isActive = false
    var granted = true
    var remainingTime: TimeInterval? = 29

    func begin(onExpiration: @escaping @MainActor () -> Void) -> Bool {
        begins += 1
        isActive = granted
        return granted
    }

    func end() {
        if isActive { ends += 1 }
        isActive = false
    }
}

@MainActor
final class SessionLifecycleTests: XCTestCase {
    func testEditableFocusReplyOpensOnlyForNewestFreshClickOnce() {
        var gate = TextFocusProbeGate()
        let first = gate.begin(epoch: 9, at: 10)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let second = gate.begin(epoch: 9, at: 10.1)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.consume(probe: first, editable: true, responseEpoch: 9,
                                    currentEpoch: 9, at: 10.2, allowed: true))
        XCTAssertTrue(gate.consume(probe: second, editable: true, responseEpoch: 9,
                                   currentEpoch: 9, at: 10.3, allowed: true))
        XCTAssertFalse(gate.consume(probe: second, editable: true, responseEpoch: 9,
                                    currentEpoch: 9, at: 10.4, allowed: true), "Reply is one-shot")
    }

    func testEditableFocusReplyRejectsLateWrongEpochNoneditableAndDismissed() {
        var gate = TextFocusProbeGate()
        let expired = gate.begin(epoch: 4, at: 20)
        XCTAssertFalse(gate.consume(probe: expired, editable: true, responseEpoch: 4,
                                    currentEpoch: 4, at: 21.01, allowed: true))
        let staleEpoch = gate.begin(epoch: 4, at: 30)
        XCTAssertFalse(gate.consume(probe: staleEpoch, editable: true, responseEpoch: 4,
                                    currentEpoch: 5, at: 30.1, allowed: true))
        let noneditable = gate.begin(epoch: 5, at: 40)
        XCTAssertFalse(gate.consume(probe: noneditable, editable: false, responseEpoch: 5,
                                    currentEpoch: 5, at: 40.1, allowed: true))
        let inactive = gate.begin(epoch: 5, at: 50)
        XCTAssertFalse(gate.consume(probe: inactive, editable: true, responseEpoch: 5,
                                    currentEpoch: 5, at: 50.1, allowed: false))
        let dismissed = gate.begin(epoch: 5, at: 60)
        gate.invalidate()
        XCTAssertFalse(gate.consume(probe: dismissed, editable: true, responseEpoch: 5,
                                    currentEpoch: 5, at: 60.1, allowed: true),
                       "Manual keyboard dismissal and modal opening invalidate pending focus")
    }

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

    func testBackgroundWithoutASessionConcealsTheSnapshotAndReturnsHome() {
        let background = FakeBackgroundExecution()
        let model = PhoneRemoteModel(background: background)
        let statusBefore = model.connection.status
        model.sceneChanged(.active)
        model.sceneChanged(.inactive)
        XCTAssertEqual(background.begins, 0, "No session means no background time is requested")
        model.sceneChanged(.background)
        XCTAssertTrue(model.contentConcealed, "The app switcher snapshot never shows the previous screen")
        XCTAssertEqual(model.resumeState, .backgrounded)
        XCTAssertFalse(model.privacyShield)
        XCTAssertEqual(model.connection.status, statusBefore, "There was nothing to disconnect")
        XCTAssertFalse(background.isActive)

        model.sceneChanged(.inactive)
        model.sceneChanged(.active)
        XCTAssertFalse(model.contentConcealed, "Returning with nothing to resume goes straight home")
        XCTAssertEqual(model.resumeState, .none)
        XCTAssertFalse(model.connection.isRunning, "Nothing reconnects on its own without a prior session")
    }

    func testBackgroundCancelsHeldInputAndPendingClipboardWork() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.sceneChanged(.active)
        model.modifiers = ["command"]
        let revision = model.inputRevision
        model.sceneChanged(.background)
        XCTAssertTrue(model.modifiers.isEmpty, "Held modifiers are released on backgrounding")
        XCTAssertGreaterThan(model.inputRevision, revision)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.clipboard.activity, .idle)
    }

    func testConcealedRecoveryCanAlwaysReturnHome() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.sceneChanged(.active)
        model.sceneChanged(.background)
        model.dismissConcealment()
        XCTAssertFalse(model.contentConcealed)
        XCTAssertEqual(model.resumeState, .none)
    }

    func testMacReportedDeparturesAreExplainedWithoutGuessing() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let time = date.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(PhoneRemoteModel.notice(for: .sleeping, at: date), "Your Mac went to sleep at \(time). Wake it to reconnect.")
        XCTAssertTrue(PhoneRemoteModel.notice(for: .locked, at: date).contains("can’t unlock it"))
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertNil(model.macNotice, "Nothing is claimed without a report from the Mac")
        XCTAssertFalse(model.canWakeDisplay)
    }

    func testClipboardActionsExplainWhyTheyAreUnavailable() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.clipboardSupported)
        XCTAssertFalse(model.clipboardAvailable)
        model.pasteToMac(["secret"])
        XCTAssertEqual(model.clipboard.notice?.message, "Connect to your Mac to use the clipboard.")
        model.copySelectionFromMac()
        XCTAssertEqual(model.clipboard.activity, .idle)
        XCTAssertFalse(model.commandShortcut("c"), "⌘C needs live control")
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
