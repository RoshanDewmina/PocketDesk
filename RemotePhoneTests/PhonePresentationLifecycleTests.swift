import XCTest
@testable import PocketDeskRemote

final class PhonePresentationLifecycleTests: XCTestCase {
    private func identity(geometry: UInt64 = 7, content: UInt64 = 1, track: UUID = UUID(), grant: String = "grant") -> VideoPresentationIdentity {
        VideoPresentationIdentity(hostRecordID: "record", ownerPairID: grant, sessionID: UUID(),
            trackID: track, contentEpoch: content, geometryEpoch: geometry)
    }
    func testCaptureDeadlineCannotBeRenewedByLiveRouteAlone() {
        let id = identity()
        let proof = PresentationLeasePolicy.admission(identity: id, routeDeadline: 20, captureHealthAt: 10,
            healthy: true, picture: true, trackPresent: true, blocked: false, now: 11)
        XCTAssertEqual(proof?.validUntil, 12)
        XCTAssertNil(PresentationLeasePolicy.admission(identity: id, routeDeadline: 25, captureHealthAt: 10,
            healthy: true, picture: true, trackPresent: true, blocked: false, now: 12))
    }
    func testAbsentRouteOwnerGeometryTrackOrLockedContentNeverAdmitted() {
        func admission(_ id: VideoPresentationIdentity? = nil, route: Double? = 11, picture: Bool = true, track: Bool = true, blocked: Bool = false) -> VideoPresentationAdmission? {
            PresentationLeasePolicy.admission(identity: id, routeDeadline: route, captureHealthAt: 9,
                healthy: true, picture: picture, trackPresent: track, blocked: blocked, now: 10)
        }
        XCTAssertNil(admission()); XCTAssertNil(admission(identity(), route: nil))
        XCTAssertNil(admission(identity(geometry: 0))); XCTAssertNil(admission(identity(), picture: false))
        XCTAssertNil(admission(identity(), track: false)); XCTAssertNil(admission(identity(), blocked: true))
    }
    func testBackgroundRequiresActualActivePiPAndHostAppliedConfirmation() {
        let proof = VideoPresentationAdmission(identity: identity(), validUntil: 12)
        for state in [LivePiPPolicy.State.ready, .starting, .paused, .stopping, .ineligible] {
            XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: state, admission: proof, viewOnlyConfirmed: true, now: 11))
        }
        XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: false, now: 11))
        XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: true, now: 12))
        XCTAssertTrue(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: true, now: 11))
    }
    func testContentOrTrackReplacementCannotResumeOldWindow() {
        let old = VideoPresentationAdmission(identity: identity(), validUntil: 12)
        var policy = LivePiPPolicy(); _ = policy.update(old, at: 10)
        XCTAssertTrue(policy.userStart(foreground: true, supported: true, possible: true, at: 10))
        XCTAssertTrue(policy.didStart(at: 10))
        XCTAssertTrue(policy.update(VideoPresentationAdmission(identity: identity(content: 2), validUntil: 13), at: 11))
        XCTAssertEqual(policy.state, .stopping)
        XCTAssertFalse(policy.mayEnqueue(old.identity, at: 11))
    }
    func testHostAppliedViewOnlyFieldRejectsWrongActionAndMissingRequestFlag() throws {
        XCTAssertNoThrow(try RemoteAction(action: "viewOnly", liveViewOnly: true, epoch: 7).validate())
        XCTAssertThrowsError(try RemoteAction(action: "viewOnly", epoch: 7).validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", liveViewOnly: true, key: "a", epoch: 7).validate())
    }
}
