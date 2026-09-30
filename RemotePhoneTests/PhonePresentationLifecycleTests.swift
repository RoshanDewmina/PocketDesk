import XCTest
@testable import PocketDeskRemote

final class PhonePresentationLifecycleTests: XCTestCase {
    private func identity(geometry: UInt64 = 7, content: UInt64 = 1, track: UUID = UUID(), grant: String = "grant") -> VideoPresentationIdentity {
        VideoPresentationIdentity(hostRecordID: "record", ownerPairID: grant, sessionID: UUID(),
            trackID: track, contentEpoch: content, geometryEpoch: geometry)
    }
    @MainActor
    func testRealModelExitTimeoutSurvivesGeometryRetirementAndRoutineStatus() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "pip-exit")
        defer { model.connection.stop() }
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
        model.stopPictureInPicture()
        let exit = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" })
        XCTAssertFalse(exit.action.liveViewOnly ?? true)
        XCTAssertNotNil(exit.action.liveViewOnlyRequestID)
        // Host drops old-geometry exit; a new geometry retires the correlation request.
        try deliver(RemoteAction(action: "geometry", x: 210, y: 200, epoch: 8))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 8, features: SessionFeature.host, mode: "picture", liveViewOnly: true))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 8, features: SessionFeature.host, mode: "picture", liveViewOnly: false))
        XCTAssertTrue(model.connection.connected, "Routine state is not an applied exit acknowledgment")
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 3)
        XCTAssertFalse(model.connection.connected, "Retirement must never erase the bounded foreground exit timeout")
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
        XCTAssertNoThrow(try RemoteAction(action: "viewOnly", liveViewOnly: true, liveViewOnlyRequestID: String(repeating: "a", count: 32), epoch: 7).validate())
        XCTAssertThrowsError(try RemoteAction(action: "viewOnly", epoch: 7).validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", liveViewOnly: true, key: "a", epoch: 7).validate())
    }
}
