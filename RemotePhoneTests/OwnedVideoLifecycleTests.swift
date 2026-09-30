import CoreGraphics
import XCTest
@testable import PocketDeskRemote

final class OwnedVideoLifecycleTests: XCTestCase {
    private func identity(_ epoch: UInt64 = 1) -> VideoPresentationIdentity {
        VideoPresentationIdentity(hostRecordID: "host-A", ownerPairID: "grant-A", sessionID: UUID(), trackID: UUID(), contentEpoch: epoch, geometryEpoch: 1)
    }
    func testMailboxNewestWinsAndBackpressureNeverAddsFlights() throws {
        let box = NewestFrameMailbox<Int>()
        for n in 0..<10_000 { _ = box.offer(n) }
        let first = try XCTUnwrap(box.take()); XCTAssertEqual(first.frame, 9999)
        _ = box.offer(10000); let second = try XCTUnwrap(box.take())
        _ = box.offer(10001); XCTAssertNil(box.take()); XCTAssertEqual(box.retainedSlots, 4)
        box.completed(first.id)
        let third = try XCTUnwrap(box.take()); XCTAssertEqual(third.frame, 10001)
        box.completed(second.id); box.completed(third.id)
        XCTAssertNil(box.take()); XCTAssertFalse(try XCTUnwrap(box.take(redraw: true)).isNew)
    }
    func testMailboxParallelArrivalsRemainBoundedAndCloseRejectsLateCompletion() {
        let box = NewestFrameMailbox<Int>()
        DispatchQueue.concurrentPerform(iterations: 2000) { _ = box.offer($0) }
        XCTAssertEqual(box.retainedSlots, 1)
        let old = box.take()!; box.invalidate()
        XCTAssertFalse(box.offer(99)); XCTAssertNil(box.take(redraw: true))
        box.completed(old.id); XCTAssertEqual(box.retainedSlots, 0)
    }
    func testFenceOldTrackAndExpiredProofCannotPublishOrRenewClosedGeneration() {
        let a = identity(), b = identity()
        let admission = VideoPresentationAdmission(identity: a, validUntil: 20)
        let fence = VideoPresentationFence(admission)
        var published: [String] = []
        _ = fence.withAdmission(a, at: 10) { published.append("A") }
        _ = fence.withAdmission(b, at: 10) { published.append("spoof") }
        _ = fence.withAdmission(a, at: 20) { published.append("expired") }
        fence.invalidate() // BEFORE interpolation flush or old drawable callback
        _ = fence.withAdmission(a, at: 11) { published.append("late") }
        XCTAssertFalse(fence.renew(admission)); XCTAssertEqual(published, ["A"])
    }
    func testInvalidationSerializesWithAlreadyAdmittedSubmission() {
        let id = identity(), fence = VideoPresentationFence(VideoPresentationAdmission(identity: id, validUntil: 100))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = fence.withAdmission(id, at: 1) { entered.signal(); _ = release.wait(timeout: .now() + 2) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { fence.invalidate(); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.01), .timedOut)
        release.signal(); XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        XCTAssertNil(fence.withAdmission(id, at: 2) { "late GPU callback" })
    }
    func testVideoRangeBlackWhiteAndFullRangeNeutralAreCorrect() {
        for matrix in [VideoColorMatrix.bt601, .bt709] {
            let video = VideoColorConversion(matrix: matrix, fullRange: false)
            let black = video.rgb(y: 16 / 255, cb: 128 / 255, cr: 128 / 255)
            let white = video.rgb(y: 235 / 255, cb: 128 / 255, cr: 128 / 255)
            for channel in [black.0, black.1, black.2] { XCTAssertEqual(channel, 0, accuracy: 0.0001) }
            for channel in [white.0, white.1, white.2] { XCTAssertEqual(channel, 1, accuracy: 0.0001) }
            let neutral = VideoColorConversion(matrix: matrix, fullRange: true).rgb(y: 0.5, cb: 128 / 255, cr: 128 / 255)
            XCTAssertEqual(neutral.0, 0.5, accuracy: 0.0001); XCTAssertEqual(neutral.1, 0.5, accuracy: 0.0001); XCTAssertEqual(neutral.2, 0.5, accuracy: 0.0001)
        }
    }
    func testKnown709RedAnd601RedVectors() {
        let r709 = VideoColorConversion(matrix: .bt709, fullRange: true).rgb(y: 0.2126, cb: Float(128.0 / 255.0) - 0.114572, cr: Float(128.0 / 255.0) + 0.5)
        let r601 = VideoColorConversion(matrix: .bt601, fullRange: true).rgb(y: 0.299, cb: Float(128.0 / 255.0) - 0.168736, cr: Float(128.0 / 255.0) + 0.5)
        for rgb in [r709, r601] { XCTAssertEqual(rgb.0, 1, accuracy: 0.001); XCTAssertEqual(rgb.1, 0, accuracy: 0.001); XCTAssertEqual(rgb.2, 0, accuracy: 0.001) }
    }
    func testSRGBTransferIsConvertedToFixed709OutputWithoutGuessing() {
        XCTAssertEqual(VideoColorTransfer.srgb.encoded709(0), 0, accuracy: 0.0001)
        XCTAssertEqual(VideoColorTransfer.srgb.encoded709(1), 1, accuracy: 0.0001)
        XCTAssertEqual(VideoColorTransfer.srgb.encoded709(0.5), 0.45019, accuracy: 0.0001)
        XCTAssertEqual(VideoColorTransfer.bt709.encoded709(0.5), 0.5)
    }
    func testCropAndClockwiseRotationKeepPictureInsideAuthorizedPixels() throws {
        let crop = CGRect(x: 40, y: 20, width: 80, height: 60)
        let size = CGSize(width: 200, height: 100)
        let expected: [Int: CGPoint] = [0: CGPoint(x: 0.2, y: 0.2), 90: CGPoint(x: 0.2, y: 0.8), 180: CGPoint(x: 0.6, y: 0.8), 270: CGPoint(x: 0.6, y: 0.2)]
        for rotation in [0, 90, 180, 270] {
            let geometry = try XCTUnwrap(VideoPixelGeometry(bufferSize: size, crop: crop, rotation: rotation))
            XCTAssertEqual(geometry.bufferUV(x: 0, y: 0), expected[rotation])
            XCTAssertEqual(geometry.displaySize, rotation % 180 == 0 ? crop.size : CGSize(width: 60, height: 80))
        }
        XCTAssertNil(VideoPixelGeometry(bufferSize: size, crop: CGRect(x: -1, y: 0, width: 20, height: 20), rotation: 0))
        XCTAssertNil(VideoPixelGeometry(bufferSize: size, crop: crop, rotation: 45))
        XCTAssertNil(VideoPixelGeometry(bufferSize: size, crop: CGRect(x: 0.5, y: 0, width: 20, height: 20), rotation: 0))
    }
    func testPiPRequiresUserForegroundStartAndCurrentProof() {
        let id = identity(); var policy = LivePiPPolicy()
        let admission = VideoPresentationAdmission(identity: id, validUntil: 10)
        XCTAssertFalse(policy.userStart(foreground: true, supported: true, possible: true, at: 1))
        XCTAssertFalse(policy.update(admission, at: 1)); XCTAssertTrue(policy.mayEnqueue(id, at: 1), "authorized inline preroll")
        XCTAssertFalse(policy.userStart(foreground: false, supported: true, possible: true, at: 1))
        XCTAssertFalse(policy.userStart(foreground: true, supported: true, possible: false, at: 1))
        XCTAssertTrue(policy.userStart(foreground: true, supported: true, possible: true, at: 1))
        XCTAssertTrue(policy.didStart(at: 2)); policy.setPlaying(false, at: 3)
        XCTAssertEqual(policy.state, .paused); XCTAssertFalse(policy.mayEnqueue(id, at: 3))
        policy.setPlaying(true, at: 4); XCTAssertTrue(policy.mayEnqueue(id, at: 4))
        XCTAssertTrue(policy.update(nil, at: 5)); XCTAssertEqual(policy.state, .stopping)
        XCTAssertFalse(policy.mayEnqueue(id, at: 5)); policy.didStop(); XCTAssertEqual(policy.state, .ineligible)
    }
    func testPiPNewGrantCannotRetargetLiveWindowAndExpiredStartFails() {
        let a = identity(), b = identity(); var policy = LivePiPPolicy()
        _ = policy.update(VideoPresentationAdmission(identity: a, validUntil: 10), at: 1)
        XCTAssertTrue(policy.userStart(foreground: true, supported: true, possible: true, at: 2))
        XCTAssertTrue(policy.didStart(at: 3))
        XCTAssertTrue(policy.update(VideoPresentationAdmission(identity: b, validUntil: 10), at: 4))
        XCTAssertFalse(policy.mayEnqueue(b, at: 4)); XCTAssertFalse(policy.mayEnqueue(a, at: 4))
        policy.didStop(); _ = policy.update(VideoPresentationAdmission(identity: b, validUntil: 10), at: 5)
        XCTAssertFalse(policy.userStart(foreground: true, supported: true, possible: true, at: 10))
    }
}
