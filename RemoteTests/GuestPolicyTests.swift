import XCTest
import CryptoKit

final class GuestPolicyTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    func testReportedTransportGenerationCoverageAndDirectionalReset() throws {
        var sampler = TransportUsageSampler()
        let first = try XCTUnwrap(sampler.sample(identity: "private-peer/private-pair", timestamp: 1, bytesSent: 1000, bytesReceived: 2000, at: 10))
        XCTAssertNil(first.sentKbps); XCTAssertEqual(first.coverage, .selectedTransport)
        let second = try XCTUnwrap(sampler.sample(identity: "private-peer/private-pair", timestamp: 2, bytesSent: 2000, bytesReceived: 4000, at: 11))
        XCTAssertEqual(first.generation, second.generation); XCTAssertEqual(second.sentKbps, 8); XCTAssertEqual(second.receivedKbps, 16)
        let reset = try XCTUnwrap(sampler.sample(identity: "private-peer/private-pair", timestamp: 3, bytesSent: 500, bytesReceived: 5000, at: 12))
        XCTAssertNotEqual(reset.generation, second.generation); XCTAssertNil(reset.sentKbps); XCTAssertNil(reset.receivedKbps)
        let changed = try XCTUnwrap(sampler.sample(identity: "private-peer/new-route", timestamp: 4, bytesSent: 1500, bytesReceived: 6000, at: 13))
        XCTAssertNotEqual(changed.generation, reset.generation)
        let text = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        XCTAssertFalse(text.contains("private-peer")); XCTAssertFalse(text.contains("new-route"))
        XCTAssertNil(sampler.sample(identity: "private-peer/new-route", timestamp: 5, bytesSent: .nan, bytesReceived: nil, at: 14))
    }
    func testCounterResetTransportReplacementAndLongIntervalNeedNewEvidence() {
        var sampler = GuestTransportSampler()
        XCTAssertNil(sampler.sample(identity: "peer1/pair1", timestamp: 1, bytesSent: 100, rttMs: 20).kbps)
        XCTAssertEqual(sampler.sample(identity: "peer1/pair1", timestamp: 2, bytesSent: 1100, rttMs: 20).kbps, 8)
        XCTAssertNil(sampler.sample(identity: "peer1/pair1", timestamp: 3, bytesSent: 50, rttMs: 20).kbps)
        XCTAssertEqual(sampler.sample(identity: "peer1/pair1", timestamp: 4, bytesSent: 550, rttMs: 20).kbps, 4)
        XCTAssertNil(sampler.sample(identity: "peer1/pair2", timestamp: 5, bytesSent: 1550, rttMs: 20).kbps)
        XCTAssertNil(sampler.sample(identity: "peer1/pair2", timestamp: 8, bytesSent: 2550, rttMs: 20).kbps)
        XCTAssertNil(sampler.sample(identity: nil, timestamp: 9, bytesSent: 3000, rttMs: 20).kbps)
        XCTAssertNil(sampler.sample(identity: "peer1/pair2", timestamp: 10, bytesSent: 4000, rttMs: 20).kbps)
    }
    func testDirectOwnerCapacityCannotBypassUnknownOrLowerGuestPathEstimate() {
        func sample(_ capacity: Double?, at: Double = 1) -> GuestTransportObservation {
            GuestTransportObservation(at: at, totalKbps: 0, capacityKbps: capacity, rttMs: nil, baselineRTTMs: nil,
                pacerDelayMs: nil, controlBufferedBytes: nil)
        }
        XCTAssertEqual(GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: 1000, guest: sample(200), at: 1.2), 200)
        XCTAssertEqual(GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: 128, guest: sample(1000), at: 1.2), 128)
        XCTAssertNil(GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: 1000, guest: sample(nil), at: 1.2))
        XCTAssertNil(GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: 1000, guest: sample(200), at: 3))
        XCTAssertNil(GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: nil, guest: sample(200), at: 1.2))
    }
    func testGuestCeilingsDoNotAddGCCAndUnknownEvidencePauses() {
        func sample(capacity: Double? = 3000, backlog: UInt64? = 0, pacer: Double? = 0, at: Double = 1) -> GuestBudgetObservation {
            GuestBudgetObservation(at: at, capacityKbps: capacity, ownerMediaKbps: 1000, fileKbps: 200, fecKbps: 100,
                guestKbps: [a: 0, b: 0], controlBufferedBytes: backlog, rttMs: 20, baselineRTTMs: 20, pacerDelayMs: pacer)
        }
        let first = GuestBudgetPolicy.ceilingKbps(for: a, observation: sample(), at: 1.2)
        let second = GuestBudgetPolicy.ceilingKbps(for: b, observation: sample(), at: 1.2)
        XCTAssertEqual(first, 336); XCTAssertEqual(second, 336)
        XCTAssertNil(GuestBudgetPolicy.ceilingKbps(for: a, observation: sample(capacity: nil), at: 1.2))
        XCTAssertNil(GuestBudgetPolicy.ceilingKbps(for: a, observation: sample(backlog: 1), at: 1.2))
        XCTAssertNil(GuestBudgetPolicy.ceilingKbps(for: a, observation: sample(pacer: nil), at: 1.2))
        XCTAssertNil(GuestBudgetPolicy.ceilingKbps(for: a, observation: sample(), at: 3))
    }
    func testPeriodicZeroAndStableKnownGuestObservationsPreserveLowRateChunkCredit() {
        for count in [0, 1] {
            let budget = MediaResourceBudget()
            budget.observe(MediaCapacityObservation(at: 0, route: "Direct", capacityKbps: 500, videoKbps: 300,
                totalTransportKbps: 300, rttMs: 20, pacerDelayMs: 0))
            var admitted = false
            for tick in 1...160 {
                let at = Double(tick) * 0.25
                budget.observe(MediaCapacityObservation(at: at, route: "Direct", capacityKbps: 500, videoKbps: 300,
                    totalTransportKbps: 300, rttMs: 20, pacerDelayMs: 0))
                budget.observeGuests(count: count, kbps: count == 0 ? 0 : 20, at: at)
                if budget.permits(bytes: 16_384, at: at, controlBuffered: 0, fileBuffered: 0) { admitted = true; break }
            }
            XCTAssertTrue(admitted, "250 ms refreshes must allow a low-rate complete chunk with \(count) guests")
        }
    }
    func testUnknownOrStaleReplicatedLoadStopsFilesAndRemovalRestoresMeasuredBudget() {
        let budget = MediaResourceBudget()
        func sample(_ at: Double) { budget.observe(MediaCapacityObservation(at: at, route: "Direct", capacityKbps: 5000, videoKbps: 1000, totalTransportKbps: 1000, rttMs: 20, pacerDelayMs: 0)) }
        sample(0); budget.observeGuests(count: 1, kbps: nil, at: 0)
        XCTAssertFalse(budget.permits(bytes: 1, at: 1, controlBuffered: 0, fileBuffered: 0))
        sample(1); budget.observeGuests(count: 2, kbps: 4500, at: 1)
        XCTAssertFalse(budget.permits(bytes: 1, at: 2, controlBuffered: 0, fileBuffered: 0))
        sample(2); budget.observeGuests(count: 1, kbps: 500, at: 2)
        XCTAssertTrue(budget.permits(bytes: 1, at: 3, controlBuffered: 0, fileBuffered: 0))
        sample(4); XCTAssertFalse(budget.permits(bytes: 1, at: 4, controlBuffered: 0, fileBuffered: 0))
        budget.observeGuests(count: 0, kbps: 0, at: 4)
        XCTAssertTrue(budget.permits(bytes: 1, at: 5, controlBuffered: 0, fileBuffered: 0))
    }
    func testActualLeaseCloseWaitsForAdmittedCaptureRejectsQueuedOldCaptureAndReplacementIsIndependent() {
        let lease = GuestCaptureLease(grantID: a, ownerSessionID: b, scopeEpoch: "1", geometryEpoch: "1", expiresAt: 100, clock: { 1 })
        lease.permit(until: 10)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { lease.deliver { entered.signal(); release.wait() } }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { lease.close(); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.05), .timedOut)
        release.signal(); XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        lease.permit(until: 99); XCTAssertFalse(lease.deliver { XCTFail("Old captured frame escaped terminal fence") })
        let replacement = GuestCaptureLease(grantID: b, ownerSessionID: a, scopeEpoch: "2", geometryEpoch: "2", expiresAt: 100, clock: { 1 })
        replacement.permit(until: 10); XCTAssertTrue(replacement.deliver {})
        replacement.pause(); XCTAssertFalse(replacement.deliver {})
    }
    func testGrantSignatureBindsRecipientScopeAndAESDirectionSessionSequence() throws {
        let signing = P256.Signing.PrivateKey(), tx = P256.KeyAgreement.PrivateKey(), rx = P256.KeyAgreement.PrivateKey()
        let publicKey = signing.publicKey.x963Representation.base64EncodedString()
        let grant = GuestGrant(hostID: a, grantID: b, ownerSessionID: a, scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window",
            requestID: b, recipientPublicKey: publicKey, recipientAgreementKey: rx.publicKey.x963Representation.base64EncodedString(),
            hostAgreementKey: tx.publicKey.x963Representation.base64EncodedString(), recipientNonce: a, hostNonce: b,
            origin: "https://guest.invalid", issuedAt: 100, expiresAt: 1000, ticketHash: a)
        try grant.validate(at: 101)
        let signature = try GuestCrypto.sign(grant.signedFields, key: signing)
        XCTAssertTrue(GuestCrypto.verify(grant.signedFields, signature: signature, publicKey: publicKey))
        var changed = grant.signedFields; changed[4] = "2"; XCTAssertFalse(GuestCrypto.verify(changed, signature: signature, publicKey: publicKey))
        changed = grant.signedFields; changed[10] = tx.publicKey.x963Representation.base64EncodedString(); XCTAssertFalse(GuestCrypto.verify(changed, signature: signature, publicKey: publicKey))
        let senderKey = try GuestCrypto.sharedKey(privateKey: tx, publicKey: grant.recipientAgreementKey, grant: grant)
        let receiverKey = try GuestCrypto.sharedKey(privateKey: rx, publicKey: grant.hostAgreementKey, grant: grant)
        let envelope = try GuestCrypto.seal(Data("offer".utf8), key: senderKey, grantID: b, sessionID: a, direction: "host", sequence: 1)
        XCTAssertEqual(try GuestCrypto.open(envelope, key: receiverKey, grantID: b, sessionID: a, direction: "host"), Data("offer".utf8))
        XCTAssertThrowsError(try GuestCrypto.open(envelope, key: receiverKey, grantID: b, sessionID: b, direction: "host"))
        XCTAssertThrowsError(try GuestCrypto.open(envelope, key: receiverKey, grantID: b, sessionID: a, direction: "guest"))
        XCTAssertThrowsError(try GuestCrypto.open(GuestSignalEnvelope(direction: "host", sequence: "2", payload: envelope.payload), key: receiverKey, grantID: b, sessionID: a, direction: "host"))
        XCTAssertThrowsError(try grant.validate(at: 1000))
    }
}
