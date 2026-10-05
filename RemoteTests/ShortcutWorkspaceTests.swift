import Foundation
import XCTest

final class ShortcutWorkspaceTests: XCTestCase {
    func testOnlySingleAllowlistedChordIsAccepted() {
        XCTAssertTrue(ScopedChordPolicy.valid(key: "s", modifiers: ["command", "shift"]))
        XCTAssertFalse(ScopedChordPolicy.valid(key: "open /tmp/a", modifiers: []))
        XCTAssertFalse(ScopedChordPolicy.valid(key: "s", modifiers: ["command", "command"]))
        XCTAssertFalse(ScopedChordPolicy.valid(key: "s", modifiers: ["hyper"]))
        XCTAssertThrowsError(try ScopedChordRequest(operation: .post, context: "old-pid", key: "s").validate())
        XCTAssertNoThrow(try ScopedChordRequest(operation: .post, context: InputCausalEnvelope.identity(), key: "s", modifiers: ["command"]).validate())
    }
    func testContextAndPostCannotMixFields() {
        XCTAssertThrowsError(try ScopedChordRequest(operation: .context, bundleID: "com.apple.Safari", key: "s").validate())
        XCTAssertThrowsError(try ScopedChordRequest(operation: .post, bundleID: "com.apple.Safari", context: InputCausalEnvelope.identity(), key: "s").validate())
        XCTAssertThrowsError(try ScopedChordReply(outcome: .posted, context: InputCausalEnvelope.identity()).validate())
    }
    func testDuplicateReliableRequestCannotReplaceAnInflightReceipt() {
        var ledger = ScopedChordRequestLedger()
        let id = InputCausalEnvelope.identity()
        XCTAssertTrue(ledger.insert(id)); XCTAssertFalse(ledger.insert(id))
        XCTAssertFalse(ledger.insert("invalid"))
        ledger.retire(); XCTAssertTrue(ledger.insert(id))
    }
    func testFreshContextRejectsPIDReuseRevokeSecureAndExpiry() {
        let launch = Date(timeIntervalSince1970: 100)
        func allowed(pid: Int32 = 7, currentLaunch: Date? = launch, generation: UInt64 = 2, secure: Bool = false, now: TimeInterval = 101) -> Bool {
            ScopedChordPolicy.current(issuedAt: 100, now: now, expectedPID: 7, currentPID: pid, expectedLaunch: launch,
                currentLaunch: currentLaunch, generation: 2, currentGeneration: generation, secure: secure)
        }
        XCTAssertTrue(allowed()); XCTAssertFalse(allowed(pid: 8)); XCTAssertFalse(allowed(currentLaunch: launch.addingTimeInterval(1)))
        XCTAssertFalse(allowed(currentLaunch: nil)); XCTAssertFalse(allowed(generation: 3)); XCTAssertFalse(allowed(secure: true)); XCTAssertFalse(allowed(now: 106))
    }
}
