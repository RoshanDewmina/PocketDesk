import CoreGraphics
import CoreVideo
import MetalKit
import WebRTC
import XCTest
@testable import PocketDeskRemote

final class OwnedVideoLifecycleTests: XCTestCase {
    @MainActor
    func testDrawablePixelsFollowOwnedCropAndRotationAcrossPinchLayoutsAndRetirement() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        XCTAssertFalse(view.metal.autoResizeDrawable)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        func offer(rotation: RTCVideoRotation, cropped: Bool) {
            let source = cropped ? RTCCVPixelBuffer(pixelBuffer: buffer, adaptedWidth: 60, adaptedHeight: 40,
                cropWidth: 120, cropHeight: 80, cropX: 20, cropY: 10) : RTCCVPixelBuffer(pixelBuffer: buffer)
            view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                frame: RTCVideoFrame(buffer: source, rotation: rotation, timeStampNs: 1),
                arrivalMs: 1, marker: nil, originalSource: true))
            view.draw(in: view.metal) // Production admission and drawable preparation, no GPU timing claim.
        }
        offer(rotation: ._0, cropped: false)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240))
        for zoom in [1.0, 3.0, 10.0] {
            view.frame = CGRect(x: 0, y: 0, width: 402 * zoom, height: 874 * zoom)
            view.setNeedsLayout(); view.layoutIfNeeded()
            XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240), "pinch layout must not allocate view-sized backing pixels")
        }
        offer(rotation: ._90, cropped: true)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 80, height: 120))
        view.invalidate()
        offer(rotation: ._0, cropped: false)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 80, height: 120), "retired source cannot reallocate a closed surface")
    }
    @MainActor
    func testAViewWhoseAspectDiffersFromTheFrameLetterboxesInsteadOfStretching() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.setNeedsLayout(); view.layoutIfNeeded()
        view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true))
        view.draw(in: view.metal)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240), "letterboxing must not resize the backing pixels")
        XCTAssertEqual(view.metal.layer.contentsGravity, .resizeAspect)
        XCTAssertEqual(view.pictureRect, CGRect(x: 0, y: 50, width: 400, height: 300), "a 4:3 frame in a square view is inset, not stretched")
        view.fillsFrame = true
        XCTAssertEqual(view.metal.layer.contentsGravity, .resize, "a cropped region still fills its placement")
        XCTAssertEqual(view.pictureRect, CGRect(x: 0, y: 0, width: 400, height: 400))
        view.fillsFrame = false
        view.frame = CGRect(x: 0, y: 0, width: 400 * 3, height: 400 * 3)
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(view.pictureRect, CGRect(x: 0, y: 150, width: 1200, height: 900))
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 301) // 0.3 % off 4:3, e.g. encoder alignment
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.metal.layer.contentsGravity, .resize, "a near match fills so the pointer overlay stays aligned")
        XCTAssertEqual(view.pictureRect, CGRect(x: 0, y: 0, width: 400, height: 301))
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 306) // 2 % off
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.metal.layer.contentsGravity, .resizeAspect)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240))
        view.invalidate()
    }
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
        let fence = VideoPresentationFence(admission, clock: { 10 })
        var published: [String] = []
        _ = fence.withAdmission(a, at: 10) { published.append("A") }
        _ = fence.withAdmission(b, at: 10) { published.append("spoof") }
        _ = fence.withAdmission(a, at: 20) { published.append("expired") }
        fence.invalidate() // BEFORE interpolation flush or old drawable callback
        _ = fence.withAdmission(a, at: 11) { published.append("late") }
        XCTAssertFalse(fence.renew(admission)); XCTAssertEqual(published, ["A"])
    }
    func testInvalidationSerializesWithAlreadyAdmittedSubmission() {
        let id = identity(), fence = VideoPresentationFence(VideoPresentationAdmission(identity: id, validUntil: 100), clock: { 1 })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = fence.withAdmission(id, at: 1) { entered.signal(); _ = release.wait(timeout: .now() + 2) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { fence.invalidate(); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.01), .timedOut)
        release.signal(); XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        XCTAssertNil(fence.withAdmission(id, at: 2) { "late GPU callback" })
    }
    func testPresenterCallbackAndMotionEntryCannotInvertPresentationFence() {
        let id = identity(), fence = VideoPresentationFence(VideoPresentationAdmission(identity: id, validUntil: 100), clock: { 1 })
        let motion = VideoMotionGate(), presenter = NSLock()
        let presenterHeld = DispatchSemaphore(value: 0), motionEntered = DispatchSemaphore(value: 0)
        let finishPresenter = DispatchSemaphore(value: 0), presenterDone = DispatchSemaphore(value: 0), drawDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            presenter.lock(); presenterHeld.signal()
            _ = finishPresenter.wait(timeout: .now() + 2)
            XCTAssertEqual(fence.withAdmission(id, at: 1, { true }), true, "presenter callback may acquire fence")
            presenter.unlock(); presenterDone.signal()
        }
        XCTAssertEqual(presenterHeld.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            // Matches production draw/config/receive: short fence check, release, enter motion.
            guard fence.withAdmission(id, at: 1, { true }) == true else { return }
            motion.perform { motionEntered.signal(); presenter.lock(); presenter.unlock() }
            drawDone.signal()
        }
        XCTAssertEqual(motionEntered.wait(timeout: .now() + 2), .success)
        let fenceReachable = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = fence.withAdmission(id, at: 1, { fenceReachable.signal() }) }
        XCTAssertEqual(fenceReachable.wait(timeout: .now() + 2), .success, "draw waits on presenter without holding fence")
        finishPresenter.signal()
        XCTAssertEqual(presenterDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(drawDone.wait(timeout: .now() + 2), .success)
        fence.invalidate()
        motion.close { XCTAssertNil(fence.withAdmission(id, at: 2, { "late flush" })) }
        XCTAssertFalse(motion.perform { XCTFail("post-close receive may not restart the motion pipeline") })
    }
    func testQueuedAdmissionUsesClockAfterWaitingForFence() {
        let id = identity()
        let clock = FenceFixtureClock(1)
        let fence = VideoPresentationFence(VideoPresentationAdmission(identity: id, validUntil: 2), clock: { clock.now })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), waiterReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = fence.withAdmission(id, at: 1) { entered.signal(); _ = release.wait(timeout: .now() + 2) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            waiterReady.signal()
            XCTAssertNil(fence.withAdmission(id, at: 1) { "expired source frame" })
            done.signal()
        }
        XCTAssertEqual(waiterReady.wait(timeout: .now() + 2), .success)
        clock.set(3) // First admission owns the actual lock; waiting call still carries at:1.
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(fence.renew(VideoPresentationAdmission(identity: id, validUntil: 2)))
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
    func testPiPPauseThenResumeRetiresBlockedConversionTicket() throws {
        var epoch = LivePiPConversionEpoch()
        let dequeued = try XCTUnwrap(epoch.ticket)
        epoch.setEnabled(false); XCTAssertFalse(epoch.accepts(dequeued)); XCTAssertNil(epoch.ticket)
        epoch.setEnabled(true)
        XCTAssertFalse(epoch.accepts(dequeued), "old conversion must not become eligible after resume")
        let current = try XCTUnwrap(epoch.ticket); XCTAssertTrue(epoch.accepts(current))
        epoch.setEnabled(true); XCTAssertTrue(epoch.accepts(current), "ordinary proof renewal does not invalidate current conversion")
    }
}

private final class FenceFixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}
