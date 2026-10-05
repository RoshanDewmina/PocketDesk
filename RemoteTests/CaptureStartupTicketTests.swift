import Foundation
import XCTest

final class CaptureStartupTicketTests: XCTestCase {
    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
    private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, file: file, line: line)
    }
    private final class Driver: @unchecked Sendable {
        let lock = NSLock()
        let startRequested = XCTestExpectation(description: "OS start requested")
        let firstStopRequested = XCTestExpectation(description: "First OS stop requested")
        var starts: [CaptureStartupTicket.Completion] = []
        var stops: [CaptureStartupTicket.Completion] = []
        var fences = 0
        var retirements = 0
        lazy var ticket = CaptureStartupTicket(
            start: { [self] completion in lock.withLock { starts.append(completion) }; startRequested.fulfill() },
            stop: { [self] completion in
                let first = lock.withLock { stops.append(completion); return stops.count == 1 }
                if first { firstStopRequested.fulfill() }
            },
            fence: { [self] in lock.withLock { fences += 1 } },
            retired: { [self] in lock.withLock { retirements += 1 } },
            stoppedError: { ($0 as NSError).domain == "test.stream" && ($0 as NSError).code == -3808 })
        var counts: (Int, Int, Int, Int) { lock.withLock { (starts.count, stops.count, fences, retirements) } }
        func settleStart(_ error: Error? = nil) {
            guard let callback = lock.withLock({ starts.first }) else { XCTFail("No start request"); return }
            callback(error)
        }
        func settleStop(_ index: Int, _ error: Error? = nil) {
            guard let callback = lock.withLock({ stops.indices.contains(index) ? stops[index] : nil }) else {
                XCTFail("No stop request at index \(index)"); return
            }
            callback(error)
        }
        func begin() -> Task<Bool, Never> {
            let ticket = ticket
            return Task { do { try await ticket.start(timeout: 10); return true } catch { return false } }
        }
        func awaitStart() async -> Bool {
            let result = await XCTWaiter.fulfillment(of: [startRequested], timeout: 3)
            if result != .completed { XCTFail("Start continuation was not registered") }
            return result == .completed
        }
    }

    func testActualDeadlineFencesAndResolvesMissingCallback() async {
        let driver = Driver(); let ticket = driver.ticket
        let failed = expectation(description: "Deadline resolved start caller")
        let task = Task {
            do { try await ticket.start(timeout: 0.02); XCTFail("Missing callback cannot become ready") }
            catch { failed.fulfill() }
        }
        defer { task.cancel() }
        await fulfillment(of: [failed, driver.firstStopRequested], timeout: 3)
        XCTAssertEqual(driver.counts.2, 1); XCTAssertEqual(driver.counts.1, 1)
        XCTAssertEqual(driver.counts.3, 0)
        XCTAssertFalse(ticket.isReady)
    }

    func testReadinessNeedsStartAndCompleteFrameInEitherOrder() async {
        for frameFirst in [true, false] {
            let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
            if frameFirst { driver.ticket.completeFrame() } else { driver.settleStart() }
            XCTAssertFalse(driver.ticket.isReady)
            if frameFirst { driver.settleStart() } else { driver.ticket.completeFrame() }
            assertTrue(await task.value)
            XCTAssertTrue(driver.ticket.isReady)
            driver.ticket.deadlineExpired()
            XCTAssertEqual(driver.counts.2, 0, "An obsolete deadline cannot fence a ready producer")
            driver.ticket.requestStop(); driver.settleStop(0)
        }
    }

    func testNoCallbackFailsCallerButKeepsProducerQuarantined() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.ticket.deadlineExpired()
        assertFalse(await task.value)
        XCTAssertEqual(driver.counts.1, 1); XCTAssertEqual(driver.counts.2, 1)
        assertFalse(await driver.ticket.waitForRetirement(timeout: 0.001))
        driver.ticket.requestStop(); driver.ticket.deadlineExpired()
        XCTAssertEqual(driver.counts.1, 1); XCTAssertEqual(driver.counts.3, 0)
    }

    func testSuccessfulStartWithoutCompleteFrameTimesOut() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.settleStart(); driver.ticket.deadlineExpired()
        assertFalse(await task.value)
        XCTAssertFalse(driver.ticket.isReady)
        driver.settleStop(0)
        assertTrue(await driver.ticket.waitForRetirement(timeout: 0.001))
        XCTAssertEqual(driver.counts.3, 1)
    }

    func testPendingStop3808CannotRetireLateSuccessfulStart() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.ticket.deadlineExpired(); assertFalse(await task.value)
        let alreadyStopped = NSError(domain: "test.stream", code: -3808)
        driver.settleStop(0, alreadyStopped)
        XCTAssertEqual(driver.counts.3, 0)
        driver.settleStart(); driver.ticket.completeFrame()
        XCTAssertFalse(driver.ticket.isReady)
        XCTAssertEqual(driver.counts.1, 2)
        driver.settleStop(1, alreadyStopped)
        assertTrue(await driver.ticket.waitForRetirement(timeout: 0.001))
        driver.settleStop(1, alreadyStopped) // A duplicate callback cannot release twice.
        driver.ticket.requestStop()
        XCTAssertEqual(driver.counts.1, 2); XCTAssertEqual(driver.counts.3, 1)
    }

    func testMissingPreStopCallbackPreventsReplacementEvenAfterLateStart() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.ticket.deadlineExpired(); assertFalse(await task.value)
        driver.settleStart()
        XCTAssertEqual(driver.counts.1, 1, "Never overlap stop requests")
        assertFalse(await driver.ticket.waitForRetirement(timeout: 0.001))
        XCTAssertEqual(driver.counts.3, 0)
    }

    func testLateStartWaitsForPreStopThenIssuesPostSettlementStop() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.ticket.requestStop(); assertFalse(await task.value)
        driver.settleStart()
        XCTAssertEqual(driver.counts.1, 1)
        driver.settleStop(0)
        XCTAssertEqual(driver.counts.1, 2)
        driver.settleStop(1)
        assertTrue(await driver.ticket.waitForRetirement(timeout: 0.001))
    }

    func testUnrelatedStopErrorDoesNotProveRetirement() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.settleStart(); driver.ticket.deadlineExpired(); assertFalse(await task.value)
        driver.settleStop(0, NSError(domain: "other", code: -3808))
        assertFalse(await driver.ticket.waitForRetirement(timeout: 0.001))
        XCTAssertEqual(driver.counts.1, 1); XCTAssertEqual(driver.counts.3, 0)
    }

    func testAlreadyCancelledTaskNeverIssuesStartOperation() async {
        let driver = Driver(); let ticket = driver.ticket
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await ticket.start(); return true } catch { return false }
        }
        assertFalse(await task.value)
        XCTAssertEqual(driver.counts.0, 0); XCTAssertEqual(driver.counts.1, 0)
        XCTAssertEqual(driver.counts.2, 1); XCTAssertEqual(driver.counts.3, 1)
    }

    func testCancellationBeforeStartDoesNotCreateOSProducer() async {
        let driver = Driver(); driver.ticket.requestStop()
        assertFalse(await driver.begin().value)
        XCTAssertEqual(driver.counts.0, 0); XCTAssertEqual(driver.counts.1, 0)
        XCTAssertEqual(driver.counts.2, 1); XCTAssertEqual(driver.counts.3, 1)
        assertTrue(await driver.ticket.waitForRetirement(timeout: 0.001))
    }

    func testTaskCancellationCannotBeRevivedByLateFrameOrCallback() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        task.cancel(); assertFalse(await task.value)
        driver.ticket.completeFrame(); driver.settleStart()
        XCTAssertFalse(driver.ticket.isReady)
        driver.settleStop(0); driver.settleStop(1)
        XCTAssertEqual(driver.counts.3, 1)
    }

    func testFailedStartStillRequiresConfirmedStop() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.settleStart(NSError(domain: "test.start", code: 1))
        assertFalse(await task.value)
        assertFalse(await driver.ticket.waitForRetirement(timeout: 0.001))
        driver.settleStop(0)
        assertTrue(await driver.ticket.waitForRetirement(timeout: 0.001))
    }

    func testReservationBlocksAnotherWrapperUntilRetirement() throws {
        let gate = CaptureProducerReservation(); let first = try gate.reserve()
        gate.retain(NSObject(), token: first)
        XCTAssertThrowsError(try gate.reserve())
        gate.release(UUID()); XCTAssertThrowsError(try gate.reserve())
        gate.release(first)
        let second = try gate.reserve(); gate.release(first)
        XCTAssertThrowsError(try gate.reserve())
        gate.release(second)
    }

    func testFaultInjectionRequiresDebugAndExplicitArgumentAndIsConsumedOnce() {
        var policy = CaptureStartupFaultPolicy()
        XCTAssertFalse(policy.consume(requested: false, debugBuild: true))
        XCTAssertFalse(policy.consume(requested: true, debugBuild: false))
        XCTAssertFalse(policy.consumed)
        XCTAssertTrue(policy.consume(requested: true, debugBuild: true))
        XCTAssertFalse(policy.consume(requested: true, debugBuild: true))
    }

    func testDuplicateStartCallbackCannotRetireHealthyProducer() async {
        let driver = Driver(); let task = driver.begin(); guard await driver.awaitStart() else { task.cancel(); return }
        driver.ticket.completeFrame(); driver.settleStart()
        assertTrue(await task.value)
        driver.settleStart(NSError(domain: "duplicate", code: 1))
        XCTAssertTrue(driver.ticket.isReady); XCTAssertEqual(driver.counts.2, 0)
        driver.ticket.requestStop(); driver.settleStop(0)
    }

    func testQueuedCallbacksCannotAdmitAfterRetirementOrScopeFence() {
        XCTAssertTrue(CaptureStartupRecoveryPolicy.admitsCallback(ready: true, scopeValid: true, stopping: false))
        XCTAssertFalse(CaptureStartupRecoveryPolicy.admitsCallback(ready: false, scopeValid: true, stopping: false))
        XCTAssertFalse(CaptureStartupRecoveryPolicy.admitsCallback(ready: true, scopeValid: false, stopping: false))
        XCTAssertFalse(CaptureStartupRecoveryPolicy.admitsCallback(ready: true, scopeValid: true, stopping: true))
    }

    func testRecoveryBudgetAndAdmissionDenials() {
        func permits(_ remaining: Bool = true, _ retired: Bool = true, _ exact: Bool = true,
                     _ picture: Bool = true, _ paused: Bool = false, _ locked: Bool = false,
                     _ permissions: Bool = true, _ trusted: Bool = true, _ viewOnly: Bool = false) -> Bool {
            CaptureStartupRecoveryPolicy.permits(remaining: remaining, retired: retired,
                exactAdmission: exact, activePicture: picture, paused: paused, locked: locked,
                permissions: permissions, routeTrusted: trusted, viewOnly: viewOnly)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(false)); XCTAssertFalse(permits(true, false))
        XCTAssertFalse(permits(true, true, false)); XCTAssertFalse(permits(true, true, true, false))
        XCTAssertFalse(permits(true, true, true, true, true))
        XCTAssertFalse(permits(true, true, true, true, false, true))
        XCTAssertFalse(permits(true, true, true, true, false, false, false))
        XCTAssertFalse(permits(true, true, true, true, false, false, true, false))
        XCTAssertFalse(permits(true, true, true, true, false, false, true, true, true))
    }
}
