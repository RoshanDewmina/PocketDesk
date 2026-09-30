import XCTest
import WebRTC
@testable import PocketDeskRemote

/// Shared derivative admission and teardown; no private RTC renderer/KVC presentation probe.
final class MiniMapVideoTests: XCTestCase {
    @MainActor
    func testMiniMapKeepsMainTimingOwnerAndGlobalRevokeClosesBothFences() {
        VideoPresentationSession.invalidateActive()
        defer { VideoPresentationSession.invalidateActive() }
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "minimap-test")
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "grant", sessionID: UUID(),
            trackID: UUID(), contentEpoch: 1, geometryEpoch: 7)
        let now = ProcessInfo.processInfo.systemUptime
        let admission = VideoPresentationAdmission(identity: identity, validUntil: now + 10)
        let main = VideoPresentationSession(track: track, admission: admission, onFrame: {})
        let mini = VideoPresentationSession(track: track, admission: admission, onFrame: {}, primary: false)
        XCTAssertTrue(VideoPresentationSession.active === main)
        XCTAssertEqual(main.fence.withAdmission(identity, at: now, { true }), true)
        XCTAssertEqual(mini.fence.withAdmission(identity, at: now, { true }), true)
        VideoPresentationSession.invalidateActive()
        XCTAssertNil(VideoPresentationSession.active)
        XCTAssertNil(main.fence.withAdmission(identity, at: now, { true }))
        XCTAssertNil(mini.fence.withAdmission(identity, at: now, { true }))
        XCTAssertFalse(main.fence.renew(admission)); XCTAssertFalse(mini.fence.renew(admission))
    }
}
