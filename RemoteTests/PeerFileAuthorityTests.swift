import XCTest

#if DEBUG && AUDIO_LIFETIME_TESTS
final class PeerFileAuthorityTests: XCTestCase {
    func testOffMainRouteRetirementWaitsForEnteredSubmissionAndDeniesEveryLaterSubmission() {
        let peer = PeerMedia(isHost: true, servers: [], fileChannel: true,
            localLink: ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20"))
        defer { peer.close() }
        peer.authorizeAudioPathForLifetimeTesting()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cutStarted = DispatchSemaphore(value: 0), cutFinished = DispatchSemaphore(value: 0)
        let submissionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = peer.withFileRouteAuthority { entered.signal(); _ = release.wait(timeout: .now()+3); return true }
            submissionFinished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now()+3), .success)
        DispatchQueue.global().async { cutStarted.signal(); peer.cutAudioPathForLifetimeTesting(); cutFinished.signal() }
        XCTAssertEqual(cutStarted.wait(timeout: .now()+3), .success)
        XCTAssertEqual(cutFinished.wait(timeout: .now()+0.05), .timedOut)
        release.signal()
        XCTAssertEqual(submissionFinished.wait(timeout: .now()+3), .success)
        XCTAssertEqual(cutFinished.wait(timeout: .now()+3), .success)
        var attempted = false
        XCTAssertNil(peer.withFileRouteAuthority { attempted = true; return true })
        XCTAssertFalse(attempted)
        XCTAssertFalse(peer.sendFile(Data([1])))
    }
}
#endif
