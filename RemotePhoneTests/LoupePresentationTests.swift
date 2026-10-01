import XCTest
import WebRTC
@testable import PocketDeskRemote

final class LoupePresentationTests: XCTestCase {
    @MainActor
    func testLoupeDerivativeSharesExactAdmissionAndGlobalTerminalRetirement() throws {
        VideoPresentationSession.invalidateActive()
        defer { VideoPresentationSession.invalidateActive() }
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "loupe")
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "owner", sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 2)
        let proof = VideoPresentationAdmission(identity: identity, validUntil: ProcessInfo.processInfo.systemUptime + 10)
        let main = VideoPresentationSession(track: track, admission: proof, onFrame: {})
        let coordinator = RemoteVideoSurface.Coordinator()
        XCTAssertTrue(coordinator.ensureSession(track: track, admission: proof, onFrame: {}, primary: false))
        let loupe = try XCTUnwrap(coordinator.session)
        loupe.configure(admission: proof, counters: nil, statistics: false, sourceSize: .zero, displayedPixelWidth: 0,
            fillsFrame: true, mode: .off, upscale: false, onSourceFrame: nil,
            sourceCrop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertTrue(VideoPresentationSession.active === main)
        VideoPresentationSession.invalidateActive()
        XCTAssertTrue(loupe.isTerminal); XCTAssertTrue(main.isTerminal)
        XCTAssertNil(loupe.fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) { true })
        XCTAssertFalse(loupe.fence.renew(proof), "A stale view update cannot revive its retired session")
        coordinator.invalidate()
    }
}
