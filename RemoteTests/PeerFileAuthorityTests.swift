import XCTest

#if DEBUG && AUDIO_LIFETIME_TESTS
final class PeerFileAuthorityTests: XCTestCase {
    @MainActor
    func testRetirementWaitsForEnteredFileIngressAndClosedPeerCannotFeedReusedTransfer() async throws {
        final class Sink: FileByteSink, @unchecked Sendable {
            private let lock = NSLock(); private var writes = 0
            var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
            func write(_ data: Data) throws { lock.lock(); writes += 1; lock.unlock() }
            func commit() throws -> URL { XCTFail("Fixture must not commit"); return URL(fileURLWithPath: "/unused") }
            func discard() {}
        }
        // Exercise only the close-ingress fence off main; native teardown stays on the main actor.
        let peer = PeerMedia(isHost: true, servers: []), queue = DispatchQueue(label: "fixture.peer-ingress")
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: FileTransferIO(queue: queue))
        let oldSink = Sink(), replacementSink = Sink(), id = FileTransferID.make()
        engine.sendControl = { _ in true }; engine.admit = { _, answer in answer(.success(oldSink)) }
        engine.receive(.offer(id, name: "old", bytes: 1, type: nil))
        let chunk = try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: Data([1])))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closing = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        defer { release.signal(); engine.reset(); peer.close() }
        peer.onFileMessage = { data in entered.signal(); release.wait(); engine.receiveChunk(data) }
        DispatchQueue.global().async { peer.deliverFileMessageForTesting(chunk) }
        XCTAssertEqual(entered.wait(timeout: .now()+3), .success)
        DispatchQueue.global().async { closing.signal(); peer.retireFileReceiveForTesting(); closed.signal() }
        XCTAssertEqual(closing.wait(timeout: .now()+3), .success)
        XCTAssertEqual(closed.wait(timeout: .now()+0.05), .timedOut, "Close ingress fence must wait for entered ingress")
        release.signal(); XCTAssertEqual(closed.wait(timeout: .now()+3), .success)
        peer.close()
        engine.reset()
        engine.admit = { _, answer in answer(.success(replacementSink)) }
        engine.receive(.offer(id, name: "replacement", bytes: 1, type: nil))
        // Even deliberate reuse of the wire ID cannot let an old callback reach the new admission.
        peer.onFileMessage = { data in engine.receiveChunk(data) }
        peer.deliverFileMessageForTesting(chunk)
        await withCheckedContinuation { c in queue.async { c.resume() } }
        XCTAssertEqual(replacementSink.count, 0, "Retired and queued old-peer bytes cannot write the replacement transfer")
    }

    func testOffMainRouteRetirementWaitsForEnteredSubmissionAndDeniesEveryLaterSubmission() {
        let peer = PeerMedia(isHost: true, servers: [],
            localLink: ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20"), fileChannel: true)
        defer { peer.close() }
        peer.authorizeAudioPathForLifetimeTesting()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cutStarted = DispatchSemaphore(value: 0), cutFinished = DispatchSemaphore(value: 0)
        let submissionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = peer.withNativeRouteSubmissionAuthority { entered.signal(); _ = release.wait(timeout: .now()+3); return true }
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
        XCTAssertNil(peer.withNativeRouteSubmissionAuthority { attempted = true; return true })
        XCTAssertFalse(attempted)
        XCTAssertFalse(peer.sendFile(Data([1])))
    }
}
#endif
