import XCTest

@MainActor
final class PhoneIdleTimerTests: XCTestCase {
    func testTransferCompletionCannotReleaseLiveViewOnlySession() {
        var writes: [Bool] = []
        let timer = PhoneIdleTimer { writes.append($0) }
        timer.setForeground(true)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        let transfer = PhoneIdleTimer.Owner.transfer(UUID())
        timer.set(transfer, active: true); timer.set(transfer, active: false)
        XCTAssertTrue(timer.isDisabled)
        XCTAssertEqual(writes, [true])
        timer.endSession()
        XCTAssertEqual(writes, [true, false])
    }
    func testSessionEndPreservesIndependentTransfersUntilEachEnds() {
        let timer = PhoneIdleTimer { _ in }
        let a = PhoneIdleTimer.Owner.transfer(UUID()), b = PhoneIdleTimer.Owner.transfer(UUID())
        timer.setForeground(true)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        timer.set(a, active: true); timer.set(b, active: true)
        timer.endSession(); timer.set(a, active: false)
        XCTAssertTrue(timer.isDisabled)
        timer.set(b, active: false)
        XCTAssertFalse(timer.isDisabled)
    }
    func testBackgroundClearsAllOwnersAndRejectsLateCallbacksBeforeReturn() {
        var writes: [Bool] = []
        let timer = PhoneIdleTimer { writes.append($0) }
        let transfer = PhoneIdleTimer.Owner.transfer(UUID())
        timer.setForeground(true)
        timer.set(transfer, active: true)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        timer.setForeground(false)
        timer.set(transfer, active: true)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        timer.setForeground(true)
        XCTAssertFalse(timer.isDisabled, "Return requires current producer state")
        XCTAssertEqual(writes, [true, false])
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        XCTAssertEqual(writes, [true, false, true])
    }
    func testExpiredUnauthenticatedPausedOrConcealedSessionReleasesIdleTimer() {
        let timer = PhoneIdleTimer { _ in }
        timer.setForeground(true)
        for denied in [(false, false, false), (true, true, false), (true, false, true)] {
            timer.updateSession(authenticated: true, paused: false, concealed: false)
            XCTAssertTrue(timer.isDisabled)
            timer.updateSession(authenticated: denied.0, paused: denied.1, concealed: denied.2)
            XCTAssertFalse(timer.isDisabled)
        }
    }
    func testNoForegroundOrOwnershipNeverDisablesAndDuplicateUpdatesDoNotWrite() {
        var writes: [Bool] = []
        let timer = PhoneIdleTimer { writes.append($0) }
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        XCTAssertFalse(timer.isDisabled)
        timer.setForeground(true)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        timer.updateSession(authenticated: true, paused: false, concealed: false)
        timer.endSession(); timer.endSession()
        XCTAssertEqual(writes, [true, false])
    }
}
