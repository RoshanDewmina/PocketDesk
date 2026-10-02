import XCTest
@testable import PocketDeskRemote

final class UsefulSessionEvidenceTests: XCTestCase {
    private let context = UsefulSessionContext(hostRecordID: "host-record", sessionID: UUID(), contentEpoch: 2, geometryEpoch: 4)
    private func id(_ value: Int) -> String { String(format: "%032x", value) }
    func testFirstPictureHoldReleasesAtOneSecondOrConfirmedSettlement() {
        var gate = FirstPictureSettlement()
        gate.begin(at: 10, hold: true)
        XCTAssertFalse(gate.refresh(at: 10.999, settled: false))
        XCTAssertTrue(gate.refresh(at: 11, settled: false))
        XCTAssertNil(gate.deadline)
        gate.begin(at: 20, hold: true)
        XCTAssertTrue(gate.refresh(at: 20.3, settled: true))
        XCTAssertNil(gate.deadline)
    }
    func testFirstPictureCancellationAndCompletedSessionNeverRehold() {
        var gate = FirstPictureSettlement()
        gate.begin(at: 10, hold: true)
        gate.cancel()
        XCTAssertFalse(gate.refresh(at: 12, settled: false), "Retired work cannot reopen a session")
        gate.begin(at: 20, hold: false)
        XCTAssertTrue(gate.ready, "A held reconnect, completed first session, Couch or rollback opens normally")
        XCTAssertNil(gate.deadline)
    }
    func testOnlyExactAcceptedAppliedReceiptIsUseful() throws {
        var tracker = AppliedInputReceiptTracker()
        let request = try XCTUnwrap(tracker.reserve(kind: "click", context: context, at: 10, requestID: id(1)))
        XCTAssertFalse(tracker.consume(.init(requestID: id(2), kind: "click", accepted: true), epoch: 4, context: context, at: 11))
        XCTAssertFalse(tracker.consume(.init(requestID: request, kind: "key", accepted: true), epoch: 4, context: context, at: 11))
        XCTAssertTrue(tracker.consume(.init(requestID: request, kind: "click", accepted: true), epoch: 4, context: context, at: 11))
        XCTAssertFalse(tracker.consume(.init(requestID: request, kind: "click", accepted: true), epoch: 4, context: context, at: 11))
    }
    func testRejectedStaleLateDifferentSessionAndEpochNeverCount() throws {
        for mode in 0..<5 {
            var tracker = AppliedInputReceiptTracker()
            let request = try XCTUnwrap(tracker.reserve(kind: "text", context: context, at: 10, requestID: id(mode + 1)))
            let other = UsefulSessionContext(hostRecordID: context.hostRecordID, sessionID: UUID(), contentEpoch: 2, geometryEpoch: 4)
            XCTAssertFalse(tracker.consume(.init(requestID: request, kind: "text", accepted: mode != 0),
                epoch: mode == 1 ? 5 : 4, context: mode == 2 ? other : context, at: mode == 3 ? 15 : mode == 4 ? 9 : 11))
            XCTAssertTrue(tracker.pending.isEmpty)
        }
    }
    func testBoundedPendingRequestsAndLifecycleCancel() {
        var tracker = AppliedInputReceiptTracker()
        XCTAssertNil(tracker.reserve(kind: "move", context: context, at: 1, requestID: id(1)))
        XCTAssertNil(tracker.reserve(kind: "key", context: context, at: .nan, requestID: id(1)))
        for i in 1...AppliedInputReceiptTracker.capacity { XCTAssertNotNil(tracker.reserve(kind: "key", context: context, at: 1, requestID: id(i))) }
        XCTAssertNil(tracker.reserve(kind: "click", context: context, at: 1, requestID: id(100)))
        tracker.cancel(id(1)); XCTAssertEqual(tracker.pending.count, 31)
        XCTAssertNotNil(tracker.reserve(kind: "click", context: context, at: 6, requestID: id(100)))
        XCTAssertEqual(tracker.pending.count, 1)
        tracker.clear(); XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testDecodedOrRepeatedSourceAloneNeverSuppliesVisiblePicture() {
        var picture = UsefulPictureEvidence()
        XCTAssertFalse(picture.visible(context: context, now: 10), "Decoded/enqueued source supplies no presentation receipt")
        let receipt = UUID()
        picture.presented(receipt, context: context, deadline: 12, now: 10)
        XCTAssertTrue(picture.visible(context: context, now: 11))
        XCTAssertEqual(picture.visibleUntil(context: context, now: 11), 12)
        picture.presented(receipt, context: context, deadline: 14, now: 11)
        XCTAssertFalse(picture.visible(context: context, now: 12), "Redraw of one original source cannot renew freshness")
        picture.presented(UUID(), context: context, deadline: 14, now: 12)
        XCTAssertTrue(picture.visible(context: context, now: 13))
        picture.invalidate(); XCTAssertFalse(picture.visible(context: context, now: 13))
    }
    func testUnknownPresentationRequiresExplicitUserConfirmationAndExactCurrentContext() {
        var picture = UsefulPictureEvidence()
        let other = UsefulSessionContext(hostRecordID: context.hostRecordID, sessionID: UUID(), contentEpoch: 2, geometryEpoch: 4)
        picture.confirmVisible(context: context, deadline: 12, now: 10)
        XCTAssertTrue(picture.userConfirmed); XCTAssertNil(picture.receiptID)
        XCTAssertTrue(picture.visible(context: context, now: 11)); XCTAssertFalse(picture.visible(context: other, now: 11))
        picture.confirmVisible(context: other, deadline: 14, now: 12)
        XCTAssertFalse(picture.visible(context: context, now: 12)); XCTAssertTrue(picture.visible(context: other, now: 13))
        picture.invalidate(); picture.confirmVisible(context: other, deadline: 14, now: 14)
        XCTAssertFalse(picture.visible(context: other, now: 14))
    }

    func testUsefulContentInputAndUserOutcomeRemainSeparate() {
        var facts = UsefulSessionEvidence()
        XCTAssertFalse(facts.confirm(.read, now: 10), "QR/connected/restore/practice supply no admission")
        facts.admit(.picture, context: context, deadline: 12, now: 10)
        XCTAssertTrue(facts.admittedPicture); XCTAssertFalse(facts.appliedInput); XCTAssertNil(facts.outcome)
        XCTAssertFalse(facts.confirm(.edit, now: 11))
        XCTAssertTrue(facts.applied(context: context, now: 11)); XCTAssertNil(facts.outcome)
        XCTAssertTrue(facts.confirm(.save, now: 11)); XCTAssertEqual(facts.outcome, .save)
        XCTAssertFalse(facts.confirm(.edit, now: 11), "No duplicate completed task from repeated taps")
        XCTAssertFalse(facts.ready(at: 12))
    }
    func testViewOnlyReadAllowedButStaleContentAndNewScopeResetFacts() {
        var facts = UsefulSessionEvidence()
        facts.admit(.picture, context: context, deadline: 12, now: 10)
        XCTAssertTrue(facts.confirm(.read, now: 11), "View-only reading requires no input")
        let changed = UsefulSessionContext(hostRecordID: "another-host", sessionID: context.sessionID, contentEpoch: 3, geometryEpoch: 5)
        facts.admit(.couch, context: changed, deadline: 14, now: 12)
        XCTAssertTrue(facts.admittedCouch); XCTAssertFalse(facts.admittedPicture); XCTAssertNil(facts.outcome)
        XCTAssertFalse(facts.applied(context: context, now: 12))
        facts.invalidate(); XCTAssertFalse(facts.confirm(.read, now: 13))
        XCTAssertTrue(facts.admittedCouch, "Historical content remains separately recorded; readiness is false")
        XCTAssertFalse(facts.ready(at: 13))
        facts.admit(.couch, context: changed, deadline: 13, now: 13); XCTAssertFalse(facts.ready(at: 13))
    }
}

@MainActor final class UsefulSessionProgressTests: XCTestCase {
    func testConsentOffThenOnAndWithdrawalDeletesOnlyAggregateCounts() {
        let name = "UsefulProgressTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let progress = UsefulSessionProgress(defaults: defaults)
        progress.count("read"); XCTAssertTrue(progress.counters.isEmpty)
        progress.setConsent(true); progress.count("read"); progress.count("credential-not-a-metric")
        XCTAssertEqual(progress.counters, ["read": 1])
        XCTAssertEqual(UsefulSessionProgress(defaults: defaults).counters, ["read": 1])
        progress.setConsent(false)
        XCTAssertNil(defaults.object(forKey: UsefulSessionProgress.countersKey))
        XCTAssertTrue(UsefulSessionProgress(defaults: defaults).counters.isEmpty)
    }
    func testReturnAndReconnectHaveDistinctCountersFromTaskOutcome() {
        let name = "UsefulReturnTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let progress = UsefulSessionProgress(defaults: defaults); progress.setConsent(true)
        func context() -> UsefulSessionContext { .init(hostRecordID: "host", sessionID: UUID(), contentEpoch: 1, geometryEpoch: 1) }
        progress.admit(.picture, context: context(), deadline: 12, now: 10)
        progress.invalidate()
        progress.admit(.picture, context: context(), deadline: 14, now: 12)
        progress.invalidate(explicitEnd: true)
        progress.admit(.couch, context: context(), deadline: 16, now: 14)
        XCTAssertEqual(progress.counters["reconnect"], 1); XCTAssertEqual(progress.counters["return"], 1)
        XCTAssertNil(progress.counters["read"]); XCTAssertNil(progress.counters["edit"])
    }
}
