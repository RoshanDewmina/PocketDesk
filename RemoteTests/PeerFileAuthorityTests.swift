import XCTest

#if DEBUG && AUDIO_LIFETIME_TESTS
final class PeerFileAuthorityTests: XCTestCase {
    func testControlIngressRefusesBurstBeforeMainHopAndFailsOnce() {
        var scheduled: [() -> Void] = [], delivered: [Int] = [], failures = 0
        let ingress = PeerControlIngress(enabled: true, schedule: { scheduled.append($0) },
            deliver: { delivered.append($0.data.count) }, fail: { _ in failures += 1 })
        for _ in 0..<64 { ingress.offer(.init(data: Data(repeating: 1, count: 4096), frames: 0, at: 0, ms: 0)) }
        XCTAssertEqual(ingress.pendingCount, 64)
        XCTAssertEqual(ingress.pendingBytes, 256 * 1024)
        XCTAssertEqual(scheduled.count, 1, "Only one main drain may be queued")
        for _ in 0..<10_000 { ingress.offer(.init(data: Data([1]), frames: 0, at: 0, ms: 0)) }
        XCTAssertEqual(ingress.pendingBytes, 0, "Overflow retires retained pending payloads")
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(failures, 1); XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testControlIngressDrainsInOrderInBoundedTurnsAndLegacySchedulesEveryMessage() {
        for enabled in [true, false] {
            var scheduled: [() -> Void] = [], delivered: [UInt8] = []
            let ingress = PeerControlIngress(enabled: enabled, schedule: { scheduled.append($0) },
                deliver: { delivered.append($0.data[0]) }, fail: { _ in XCTFail("No overflow expected") })
            for value in 0..<40 { ingress.offer(.init(data: Data([UInt8(value)]), frames: value, at: 0, ms: 0)) }
            XCTAssertEqual(scheduled.count, enabled ? 1 : 40)
            scheduled.removeFirst()()
            XCTAssertEqual(delivered.count, enabled ? 16 : 1)
            while !scheduled.isEmpty { scheduled.removeFirst()() }
            XCTAssertEqual(delivered, (0..<40).map(UInt8.init))
            XCTAssertEqual(ingress.pendingBytes, 0)
        }
    }

    func testControlIngressKillSwitchDefaultsOnAndExplicitNoRestoresLegacy() {
        let name = "fixture.control-ingress." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(PeerControlIngress.isEnabled(defaults: defaults))
        defaults.set(false, forKey: "PocketDeskControlIngressBudget")
        XCTAssertFalse(PeerControlIngress.isEnabled(defaults: defaults))
    }

    func testControlIngressChargesInFlightDeliveryAndRejectsMalformedFloodOnce() {
        var scheduled: [() -> Void] = [], failures = 0
        var ingress: PeerControlIngress!
        ingress = PeerControlIngress(enabled: true, schedule: { scheduled.append($0) }, deliver: { _ in
            XCTAssertEqual(ingress.pendingCount, 64)
            ingress.offer(.init(data: Data([1]), frames: 0, at: 0, ms: 0))
            XCTAssertEqual(ingress.pendingCount, 1, "Entered callback remains charged after queued payloads retire")
        }, fail: { _ in failures += 1 })
        for _ in 0..<64 { ingress.offer(.init(data: Data([1]), frames: 0, at: 0, ms: 0)) }
        scheduled.removeFirst()()
        XCTAssertEqual(ingress.pendingCount, 0); XCTAssertEqual(ingress.pendingBytes, 0)
        XCTAssertEqual(failures, 1); XCTAssertTrue(scheduled.isEmpty)

        let invalid = PeerControlIngress(enabled: true, schedule: { scheduled.append($0) },
            deliver: { _ in XCTFail("Malformed data must not deliver") }, fail: { _ in failures += 1 })
        for _ in 0..<10_000 { invalid.offer(.init(data: Data([1]), frames: 0, at: 0, ms: 0), valid: false) }
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(failures, 2)
    }

    func testControlIngressAssociationBoundsThePeerAcrossChannelObjects() {
        let peer = NSObject(), another = NSObject()
        let first = PeerControlIngress.forPeer(peer) {
            PeerControlIngress(schedule: { _ in }, deliver: { _ in }, fail: { _ in })
        }
        XCTAssertTrue(PeerControlIngress.forPeer(peer) { XCTFail("No second ingress for this peer"); return first } === first)
        XCTAssertFalse(PeerControlIngress.forPeer(another) {
            PeerControlIngress(schedule: { _ in }, deliver: { _ in }, fail: { _ in })
        } === first)
    }

    func testControlIngressRejectsForeignSourcesButPreservesPendingControlAdoption() {
        let current = NSObject(), foreign = NSObject()
        XCTAssertTrue(PeerControlIngress.permitsSource(current: current, source: current, label: "control", ordered: true, reliable: true))
        XCTAssertFalse(PeerControlIngress.permitsSource(current: current, source: foreign, label: "control", ordered: true, reliable: true))
        XCTAssertTrue(PeerControlIngress.permitsSource(current: nil, source: current, label: "control", ordered: true, reliable: true))
        XCTAssertFalse(PeerControlIngress.permitsSource(current: nil, source: foreign, label: "unknown", ordered: true, reliable: true))
        XCTAssertFalse(PeerControlIngress.permitsSource(current: nil, source: foreign, label: "control", ordered: false, reliable: true))
    }

    func testControlIngressRefusalDuringDeliveryClosesPendingReliablePrefixOnce() {
        let peer = NSObject()
        var scheduled: [() -> Void] = [], delivered = 0, failures = 0
        let ingress = PeerControlIngress.forPeer(peer) {
            PeerControlIngress(enabled: true, schedule: { scheduled.append($0) }, deliver: { _ in
                delivered += 1; PeerControlIngress.refusePeer(peer)
            }, fail: { _ in failures += 1 })
        }
        for _ in 0..<40 { ingress.offer(.init(data: Data([1]), frames: 0, at: 0, ms: 0)) }
        scheduled.removeFirst()()
        XCTAssertEqual(delivered, 1); XCTAssertEqual(failures, 1)
        XCTAssertEqual(ingress.pendingCount, 0); XCTAssertTrue(scheduled.isEmpty)
    }

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
