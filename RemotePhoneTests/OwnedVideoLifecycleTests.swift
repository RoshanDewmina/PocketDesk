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
        let landscape = CGSize(width: 320, height: 240)
        XCTAssertEqual(view.metal.drawableSize, landscape, "the first picture is drawn 1:1")
        XCTAssertEqual(view.metal.layer.contentsGravity, .resize, "Core Animation fills the picture placement")
        var pinched: [CGSize] = []
        for zoom in [0.25, 1.0, 3.0, 10.0] {
            view.frame = CGRect(x: 0, y: 0, width: 402 * zoom, height: 874 * zoom)
            view.setNeedsLayout(); view.layoutIfNeeded()
            view.draw(in: view.metal) // The relayout redraw is what would resize the drawable.
            pinched.append(view.metal.drawableSize)
        }
        XCTAssertEqual(pinched, Array(repeating: landscape, count: 4),
                       "pinch layout neither allocates view-sized backing pixels nor resizes per frame")
        offer(rotation: ._90, cropped: true)
        let rotated = CGSize(width: 80, height: 120)
        XCTAssertEqual(view.metal.drawableSize, rotated, "only an aspect change (rotation) resizes the backing")
        view.invalidate()
        offer(rotation: ._0, cropped: false)
        XCTAssertEqual(view.metal.drawableSize, rotated, "retired source cannot reallocate a closed surface")
    }
    func testBackingSizeRatchetsToTheLargestPictureAndIgnoresStepsWobbleAndPinch() {
        let full = OwnedMetalVideoView.backingSize(picture: CGSize(width: 2560, height: 1600), current: nil)
        XCTAssertEqual(full, CGSize(width: 2560, height: 1600), "the top rung is drawn 1:1")
        for smaller in [CGSize(width: 1920, height: 1200), CGSize(width: 1680, height: 1050), CGSize(width: 1280, height: 800),
                        CGSize(width: 2560, height: 1598), CGSize(width: 2560, height: 1640), CGSize(width: 1448, height: 928), CGSize(width: 1456, height: 928)] {
            XCTAssertEqual(OwnedMetalVideoView.backingSize(picture: smaller, current: full), full, "\(smaller) keeps the drawable")
        }
        XCTAssertEqual(OwnedMetalVideoView.backingSize(picture: CGSize(width: 1600, height: 2560), current: full),
                       CGSize(width: 1600, height: 2560), "a rotation is a real aspect change")
        XCTAssertEqual(OwnedMetalVideoView.backingSize(picture: CGSize(width: 3000, height: 1875), current: full),
                       CGSize(width: 3000, height: 1875), "a larger picture grows the drawable once, at its exact aspect")
        XCTAssertEqual(OwnedMetalVideoView.backingSize(picture: CGSize(width: 8000, height: 4000), current: nil), CGSize(width: 4096, height: 2048))
        XCTAssertEqual(OwnedMetalVideoView.backingSize(picture: .zero, current: full), full)
    }
    @MainActor
    func testLadderResolutionStepsNeverReallocateTheDrawableAndEveryDrawPresents() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 251); view.setNeedsLayout(); view.layoutIfNeeded()
        var sizes: [CGSize] = [], presented: [Int] = []
        /// At most two command buffers fly; a frame taken while both are out waits for the next tick.
        func draw() {
            let before = view.drawsPresented
            for _ in 0..<200 {
                view.draw(in: view.metal)
                if view.drawsPresented > before { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        for (width, height) in [(256, 160), (128, 80), (192, 120), (256, 164), (256, 160)] { // 256×164 is 2.5 % off
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(sizes.count + 1)),
                arrivalMs: 1, marker: nil, originalSource: true))
            draw()
            sizes.append(view.metal.drawableSize); presented.append(view.drawsPresented)
        }
        XCTAssertEqual(Set(sizes).count, 1, "2560→1280→1920 style steps share one drawable: \(sizes)")
        XCTAssertEqual(presented, [1, 2, 3, 4, 5], "every draw presented the latest frame; no blank pass")
        XCTAssertFalse(view.subviews.contains { $0 is RTCMTLVideoView }, "no black fallback view was ever shown")
        view.invalidate()
    }
    /// Core Animation calls presented handlers holding the layer lock that `addPresentedHandler`
    /// needs on main while main holds the fence (8BADF00D reports from build 20260930.8).
    @MainActor
    func testPresentedReceiptNeverWaitsOnTheDrawFence() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let fence = VideoPresentationFence(admission)
        let view = OwnedMetalVideoView(admission: admission, fence: fence)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true)
        let delivered = expectation(description: "receipt delivered once the draw releases the fence")
        let receipt = view.presentedReceipt(envelope) { identity, receiptID in
            XCTAssertEqual(identity, id); XCTAssertEqual(receiptID, envelope.receiptID); delivered.fulfill()
        }
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = fence.withAdmission(id, at: ProcessInfo.processInfo.systemUptime) { held.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { receipt(1); returned.signal() } // Stands in for Core Animation's presented-callback thread.
        XCTAssertEqual(returned.wait(timeout: .now() + 0.5), .success, "presented handler blocked on the fence held by the drawing thread")
        release.signal()
        wait(for: [delivered], timeout: 2)

        let late = expectation(description: "no receipt after retirement"); late.isInverted = true
        let retired = view.presentedReceipt(envelope) { _, _ in late.fulfill() }
        view.invalidate()
        retired(1)
        wait(for: [late], timeout: 0.3)
    }
    @MainActor
    func testInlinePresentationRecoversWithFreshLifetimeAfterProofGap() throws {
        let id = identity()
        let first = try XCTUnwrap(VideoPresentationAdmission.renewed(
            VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 10), from: nil))
        XCTAssertNil(VideoPresentationAdmission.renewed(nil, from: first), "stale capture health withdraws the proof")
        XCTAssertFalse(first.lifetime.isActive)
        let back = try XCTUnwrap(VideoPresentationAdmission.renewed(
            VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 10), from: nil))
        XCTAssertTrue(back.permits(at: ProcessInfo.processInfo.systemUptime))
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "gap-recovery")
        let coordinator = RemoteVideoSurface.Coordinator()
        defer { coordinator.invalidate() }
        XCTAssertFalse(coordinator.ensureSession(track: track, admission: first, onFrame: {}, primary: false))
        XCTAssertTrue(coordinator.ensureSession(track: track, admission: back, onFrame: {}, primary: false))
        XCTAssertNotNil(coordinator.session?.fence.withAdmission(id, at: ProcessInfo.processInfo.systemUptime) { true })
    }
    @MainActor
    func testThePictureFillsItsPlacementWhateverTheAspectSoOverlaysStayOnTarget() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 306) // 2 % off 4:3
        view.setNeedsLayout(); view.layoutIfNeeded()
        view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true))
        view.draw(in: view.metal)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 320, height: 240), "the placement never resizes the backing pixels")
        for fills in [false, true] {
            view.fillsFrame = fills
            XCTAssertEqual(view.metal.layer.contentsGravity, .resize)
            XCTAssertEqual(view.pictureRect, CGRect(x: 0, y: 0, width: 400, height: 306))
        }
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
    @MainActor
    func testRendererKillSwitchesAreIndependentAndDefaultOn() throws {
        let name = "OwnedVideoLifecycleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        func make() -> OwnedMetalVideoView {
            OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        }
        let enabled = make(); defer { enabled.invalidate() }
        XCTAssertTrue(enabled.renderOptimizations.unfencedDrawable); XCTAssertTrue(enabled.renderOptimizations.promptSourceDraw)
        defaults.set(true, forKey: "phoneUnfencedDrawableDisabled")
        let fenced = make(); defer { fenced.invalidate() }
        XCTAssertFalse(fenced.renderOptimizations.unfencedDrawable); XCTAssertTrue(fenced.renderOptimizations.promptSourceDraw)
        defaults.set(false, forKey: "phoneUnfencedDrawableDisabled")
        defaults.set(true, forKey: "phoneImmediateSourceDrawDisabled")
        let paced = make(); defer { paced.invalidate() }
        XCTAssertTrue(paced.renderOptimizations.unfencedDrawable); XCTAssertFalse(paced.renderOptimizations.promptSourceDraw)
    }
    func testMailboxPresentationOccupancySurvivesGPUCompletionInEitherOrder() throws {
        let box = NewestFrameMailbox<Int>()
        box.offer(1); let first = try XCTUnwrap(box.take(holdUntilPresented: true))
        box.offer(2); let second = try XCTUnwrap(box.take(holdUntilPresented: true))
        box.gpuCompleted(first.id); box.gpuCompleted(second.id)
        box.offer(3); box.offer(4)
        XCTAssertNil(box.take(holdUntilPresented: true), "GPU completion alone cannot admit a third drawable")
        box.presented(first.id)
        let newest = try XCTUnwrap(box.take(holdUntilPresented: true)); XCTAssertEqual(newest.frame, 4)
        box.presented(newest.id)
        box.offer(5)
        XCTAssertNil(box.take(holdUntilPresented: true), "presentation before GPU completion still retains GPU ownership")
        box.gpuCompleted(newest.id)
        XCTAssertEqual(try XCTUnwrap(box.take(holdUntilPresented: true)).frame, 5)
        box.completed(second.id)
    }
    func testFailedAcquisitionRequeuesOnlyWithoutANewerArrivalAndCloseIsTerminal() throws {
        let box = NewestFrameMailbox<Int>()
        box.offer(1); let first = try XCTUnwrap(box.take(holdUntilPresented: true))
        box.offer(2); box.requeue(first.id, frame: first.frame, wasNew: first.isNew)
        XCTAssertEqual(try XCTUnwrap(box.take(holdUntilPresented: true)).frame, 2)
        box.invalidate(); box.completed(first.id); box.presented(first.id)
        XCTAssertFalse(box.offer(3)); XCTAssertNil(box.take(redraw: true))
    }
    @MainActor
    func testDrawableAcquisitionAllowsDecodedDeliveryAndPrivacyRetirement() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let fence = VideoPresentationFence(admission)
        let view = OwnedMetalVideoView(admission: admission, fence: fence)
        defer { view.invalidate() }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true)
        view.offer(envelope)
        view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        view.setNeedsLayout(); view.layoutIfNeeded()
        let actualAcquirer = view.drawableAcquirer
        var acquired = false
        view.drawableAcquirer = { metal in
            acquired = true
            let drawable = actualAcquirer(metal)
            XCTAssertNotNil(drawable, "test needs a successful preparation to exercise the final admission recheck")
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                view.offer(envelope)
                admission.lifetime.retire()
                delivered.signal()
            }
            XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success,
                           "delivery or privacy retirement blocked on drawable acquisition")
            return drawable
        }
        view.draw(in: view.metal)
        view.drawableAcquirer = actualAcquirer // Break the test hook's view capture.
        XCTAssertTrue(acquired)
        XCTAssertEqual(view.drawsPresented, 0)
        XCTAssertNil(fence.withAdmission(id, at: ProcessInfo.processInfo.systemUptime) { true })
    }
    @MainActor
    func testActivePassThroughWakesCoalesceAndSkipSourcesConsumedByATick() async throws {
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.drawRequester = { $0.draw() }; view.invalidate() }
        view.metal.isPaused = true
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        func envelope(_ stamp: Int64, prompt: Bool) -> VideoFrameEnvelope {
            VideoFrameEnvelope(receiptID: UUID(), identity: admission.identity,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: stamp),
                arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true, promptDraw: prompt)
        }
        var requests = 0
        view.drawRequester = { _ in
            requests += 1
            if let frame = view.mailbox.take() { view.mailbox.completed(frame.id) }
        }
        func drainMain() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        view.offer(envelope(1, prompt: true)); view.offer(envelope(2, prompt: true))
        await drainMain()
        XCTAssertEqual(requests, 1, "active arrivals coalesce into one prompt request")
        view.offer(envelope(3, prompt: true))
        let tick = try XCTUnwrap(view.mailbox.take()); view.mailbox.completed(tick.id)
        await drainMain()
        XCTAssertEqual(requests, 1, "a display tick consuming the source cancels its redundant queued wake")
        view.offer(envelope(4, prompt: false)); await drainMain()
        XCTAssertEqual(requests, 1, "paced interpolation output does not request an active immediate draw")
    }
    func testPromptPendingIsConsumedOnceAndPacedOutputDoesNotWake() throws {
        let box = NewestFrameMailbox<(Int, Bool)>()
        box.offer((1, true)); box.offer((2, true))
        XCTAssertTrue(box.hasPending(where: { $0.1 }))
        let source = try XCTUnwrap(box.take()); XCTAssertEqual(source.frame.0, 2)
        XCTAssertFalse(box.hasPending(where: { $0.1 }), "queued wake after a tick must not submit again")
        XCTAssertNil(box.take())
        box.completed(source.id); box.offer((3, false))
        XCTAssertFalse(box.hasPending(where: { $0.1 }), "interpolator outputs remain paced")
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
