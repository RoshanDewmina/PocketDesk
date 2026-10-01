import Foundation
import XCTest

final class HostAXBrokerTests: XCTestCase {
    func testResultWithinBudgetIsDelivered() async {
        let broker = HostAXBroker(label: "test.ax.fast")
        let value = await broker.run(budget: 0.5) { _ in 42 }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(broker.isBusy)
    }

    func testLateResultIsRejectedAtTheDeadlineWhileTheLaneStaysBusy() async {
        let broker = HostAXBroker(label: "test.ax.slow")
        let started = Date()
        let value = await broker.run(budget: 0.05) { _ -> Int? in
            Thread.sleep(forTimeInterval: 0.3)
            return 7
        }
        XCTAssertNil(value, "A reply after the total budget is discarded")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "The caller hears back by the deadline")
        XCTAssertTrue(broker.isBusy, "The blocked AX call still owns the lane")
        let dropped = await broker.run(budget: 0.5) { _ in 1 }
        XCTAssertNil(dropped, "A new query is dropped, never queued behind a slow app")
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(broker.isBusy)
        let recovered = await broker.run(budget: 0.5) { _ in 2 }
        XCTAssertEqual(recovered, 2)
    }

    /// A double tap cancels the first tap's focus probe, but its AX call keeps the lane. The second
    /// tap's probe used to be dropped and answered "not editable", so the keyboard never opened.
    func testSupersededSlowQueryDoesNotDropTheNextFocusProbe() async {
        let broker = HostAXBroker(label: "test.ax.superseded")
        let first = Task { await broker.run(budget: 0.25) { _ -> Int? in Thread.sleep(forTimeInterval: 0.15); return 1 } }
        try? await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let firstValue = await first.value
        XCTAssertNil(firstValue)
        XCTAssertTrue(broker.isBusy, "The cancelled first-tap AX call still owns the lane")
        let second = await broker.run(budget: 0.25, waitForLane: HostTextFocusProbe.lanePatience) { _ in 2 }
        XCTAssertEqual(second, 2, "The double tap's probe waits for the lane instead of reporting non-editable")

        let hog = Task { await broker.run(budget: 0.05) { _ -> Int? in Thread.sleep(forTimeInterval: 0.6); return 3 } }
        _ = await hog.value
        let started = Date()
        let starved = await broker.run(budget: 0.25, waitForLane: 0.1) { _ in 4 }
        XCTAssertNil(starved, "patience is bounded: a hung app still drops the query")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    }

    func testBudgetShrinksPerCallTimeoutAndStopsWhenSpent() {
        var now: TimeInterval = 100
        let budget = HostAXBudget(total: 0.2, clock: { now })
        XCTAssertEqual(budget.nextCallTimeout, Float(HostAXBudget.perCall))
        now = 100.15
        XCTAssertEqual(Double(budget.nextCallTimeout ?? 0), 0.05, accuracy: 0.0001)
        now = 100.2
        XCTAssertNil(budget.nextCallTimeout)
        XCTAssertTrue(budget.isExhausted)
        let cancelled = HostAXBudget(total: 1, clock: { 0 })
        cancelled.cancel()
        XCTAssertNil(cancelled.nextCallTimeout)
    }

    func testCancelledCallerGetsNothing() async {
        let broker = HostAXBroker(label: "test.ax.cancel")
        let task = Task { await broker.run(budget: 1) { _ -> Int? in Thread.sleep(forTimeInterval: 0.2); return 3 } }
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
    }

    func testRefreshProbeWithoutClickFailsClosedOnBadInput() async {
        let result = await HostTextFocusProbe.focus(at: CGPoint(x: CGFloat.infinity, y: 0), geometry: true)
        XCTAssertEqual(result, .unfocused)
    }
}
