import XCTest
@testable import RemoteCoreTests

final class VideoAdmissionLifetimeTests: XCTestCase {
    private func proof() -> VideoPresentationAdmission {
        VideoPresentationAdmission(identity: VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "grant",
            sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 1), validUntil: 100)
    }
    func testCachedProofCannotReopenNewFenceAfterSharedRetirement() {
        let p = proof(), main = VideoPresentationFence(p, clock: { 1 }), derivative = VideoPresentationFence(p, clock: { 1 })
        p.lifetime.retire()
        for fence in [main, derivative, VideoPresentationFence(p, clock: { 1 })] {
            XCTAssertNil(fence.withAdmission(p.identity, at: 1) { true })
            XCTAssertFalse(fence.renew(p))
        }
        XCTAssertFalse(p.permits(at: 1))
        let fresh = VideoPresentationAdmission(identity: p.identity, validUntil: 100)
        XCTAssertEqual(VideoPresentationFence(fresh, clock: { 1 }).withAdmission(p.identity, at: 1) { true }, true)
    }
    func testLocalViewTeardownDoesNotRetireAnotherViewOrPiP() {
        let p = proof(), local = VideoPresentationFence(p, clock: { 1 }), other = VideoPresentationFence(p, clock: { 1 })
        let pip = VideoPresentationAdmission(identity: p.identity, validUntil: 100)
        local.invalidate()
        XCTAssertTrue(p.permits(at: 1)); XCTAssertEqual(other.withAdmission(p.identity, at: 1) { true }, true)
        p.lifetime.retire(); XCTAssertTrue(pip.permits(at: 1))
    }
    func testOnlyCurrentModelRenewalPreservesLifetimeAndCannotRetargetExistingFence() {
        let p = proof(), candidate = VideoPresentationAdmission(identity: p.identity, validUntil: 150)
        let renewed = VideoPresentationAdmission.renewed(candidate, from: p)!
        XCTAssertTrue(renewed.lifetime === p.lifetime)
        let fence = VideoPresentationFence(p, clock: { 1 })
        XCTAssertTrue(fence.renew(renewed)); XCTAssertFalse(fence.renew(candidate))
        XCTAssertNil(VideoPresentationAdmission.renewed(nil, from: renewed))
        XCTAssertFalse(renewed.permits(at: 1))
    }
    func testRetirementWaitsForEnteredFinalEffectThenRejectsAllLateEffects() {
        let p = proof(), fence = VideoPresentationFence(p, clock: { 1 })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = fence.withAdmission(p.identity, at: 1) { entered.signal(); _ = release.wait(timeout: .now() + 2) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { p.lifetime.retire(); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 0.05), .timedOut)
        release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertNil(fence.withAdmission(p.identity, at: 1) { XCTFail("Retired effect ran") })
    }
}
