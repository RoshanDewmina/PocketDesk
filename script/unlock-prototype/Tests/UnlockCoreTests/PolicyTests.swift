import XCTest
@testable import UnlockCore
final class PolicyTests: XCTestCase {
    func testOnlyExplicitLockedDisposableConsoleCanReceivePassword() {
        XCTAssertTrue(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: true, locked: true, deadline: 110, now: 100))
        for uid in [UInt32(0), 501] {
            XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: uid, onConsole: true, locked: true, deadline: 110, now: 100))
        }
        XCTAssertFalse(Policy.canType(enabled: false, expectedUID: 502, actualUID: 502, onConsole: true, locked: true, deadline: 110, now: 100))
        XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: true, locked: nil, deadline: 110, now: 100))
        XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: false, locked: true, deadline: 110, now: 100))
        XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: true, locked: false, deadline: 110, now: 100))
        XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: true, locked: true, deadline: 100, now: 100))
        XCTAssertFalse(Policy.canType(enabled: true, expectedUID: 502, actualUID: 502, onConsole: true, locked: true, deadline: 131, now: 100))
    }
    func testPasswordAlphabetHasNoShortcutOrControlCharacter() {
        XCTAssertTrue(Policy.validPassword(Data("abcxyz0123456789".utf8)))
        for value in ["", "a\n", "A", "é", "a\t", String(repeating: "a", count: 65)] {
            XCTAssertFalse(Policy.validPassword(Data(value.utf8)))
        }
    }
    func testAttemptBudgetExpiresAndRejectsClockRollback() {
        var budget = AttemptBudget()
        XCTAssertTrue(budget.take(now: 100))
        XCTAssertFalse(budget.take(now: 110))
        XCTAssertFalse(budget.take(now: 90))
        XCTAssertTrue(budget.take(now: 130))
        XCTAssertTrue(budget.take(now: 160))
        XCTAssertFalse(budget.take(now: 190))
    }
}
