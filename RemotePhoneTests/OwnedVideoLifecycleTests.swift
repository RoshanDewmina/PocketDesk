import CoreGraphics
import CoreVideo
import MetalKit
import WebRTC
import XCTest
@testable import PocketDeskRemote

final class OwnedVideoLifecycleTests: XCTestCase {
    @MainActor
    func testUnacceptedSmartZoomCleanupRestoresCompatibilityFallbackAndRejectsStaleCleanup() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.metal.isPaused = true
        view.drawRequester = { _ in }
        view.drawableAcquirer = { _ in nil }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true)
        let visible = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertTrue(view.beginViewportCoverage(generation: 1, required: visible, scope: 1))
        XCTAssertTrue(view.beginViewportCoverage(generation: 2, required: visible, scope: 1))
        view.finishViewportCoverage(generation: 1, required: visible)
        view.offer(envelope); view.draw(in: view.metal)
        XCTAssertEqual(view.fallbackCreationCount, 0, "Older cancellation must not remove the new camera fence")
        XCTAssertFalse(view.viewportCoverageReady(generation: 2))
        // A queued covering presentation before the first camera sample is still an aborted zoom.
        let region = CaptureRegion(epoch: 0, x: 0, y: 0, width: 64, height: 64, outputWidth: 64, outputHeight: 64)
        let tagged = VideoFrameEnvelope(receiptID: UUID(), identity: id, frame: envelope.frame,
            arrivalMs: 1, marker: nil, originalSource: true,
            videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
                geometryEpoch: 1, scopeEpoch: 1, ltrToken: nil, region: region))
        view.viewportCoveragePresented(tagged, generation: 2, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(view.viewportCoverageReady(generation: 2))
        view.finishViewportCoverage(generation: 2, required: visible)
        view.offer(envelope); view.draw(in: view.metal)
        XCTAssertEqual(view.fallbackCreationCount, 1, "Timeout before camera acceptance must restore untagged compatibility rendering")
        XCTAssertFalse(view.viewportCoverageReady(generation: 2), "Fallback is not a positive presentation receipt")
    }

    @MainActor
    func testSmartZoomMotionDrainsOldCropFlightsThenRejectsLateNarrowPresentationAndRetainsSafeEndpoint() async throws {
        for gpuFirst in [true, false] {
            let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
            let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
            defer { view.invalidate() }
            view.metal.isPaused = true
            view.drawRequester = { _ in }
            let full = CaptureRegion(epoch: 0, x: 0, y: 0, width: 200, height: 100, outputWidth: 200, outputHeight: 100)
            let narrow = CaptureRegion(epoch: 9, x: 60, y: 20, width: 80, height: 40, outputWidth: 80, outputHeight: 40)
            func frame(_ region: CaptureRegion, original: Bool = true, scope: UInt64 = 1, geometry: UInt64 = 1) throws -> VideoFrameEnvelope {
                var pixels: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(nil, region.outputWidth, region.outputHeight, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
                return .init(receiptID: UUID(), identity: admission.identity,
                    frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1),
                    arrivalMs: MachClock.nowMs(), marker: nil, originalSource: original,
                    videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
                        geometryEpoch: geometry, scopeEpoch: scope, ltrToken: nil, region: region))
            }
            let wide = try frame(full), crop = try frame(narrow)
            func drainReceiptQueue() async {
                await withCheckedContinuation { continuation in
                    OwnedMetalVideoView.presentedReceiptQueue.async {
                        DispatchQueue.main.async { continuation.resume() }
                    }
                }
            }
            XCTAssertTrue(view.beginViewportCoverage(generation: 9, required: full.rect, scope: 1))
            let staleReceipt = try XCTUnwrap(view.viewportCoverageReceipt(wide))
            // Stand in for a narrow submission already committed before return begins.
            view.mailbox.offer(crop)
            let old = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            XCTAssertTrue(view.beginViewportCoverage(generation: 10, required: full.rect, scope: 1))
            view.mailbox.offer(wide)
            let covering = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            XCTAssertFalse(view.viewportCoverageAllows(wide, submissionID: covering.id))
            if gpuFirst { view.mailbox.gpuCompleted(old.id) } else { view.mailbox.presented(old.id) }
            XCTAssertFalse(view.viewportCoverageAllows(wide, submissionID: covering.id), "One old completion edge cannot admit widening")
            if gpuFirst { view.mailbox.presented(old.id) } else { view.mailbox.gpuCompleted(old.id) }
            XCTAssertTrue(view.viewportCoverageAllows(wide, submissionID: covering.id))
            XCTAssertFalse(view.viewportCoverageReady(generation: 10), "Submission/drain is not a physical receipt")
            staleReceipt(ProcessInfo.processInfo.systemUptime)
            await drainReceiptQueue()
            XCTAssertFalse(view.viewportCoverageReady(generation: 10), "Old wide receipts cannot start a new camera")
            let coveringReceipt = try XCTUnwrap(view.viewportCoverageReceipt(wide))
            coveringReceipt(ProcessInfo.processInfo.systemUptime)
            await drainReceiptQueue()
            XCTAssertTrue(view.viewportCoverageReady(generation: 10))
            view.synchronizeViewportCoverage(visible: full.rect)
            XCTAssertFalse(view.viewportCoverageAllows(crop, submissionID: covering.id), "Unchanged endpoint observation must keep late narrow crops withheld")
            XCTAssertFalse(view.viewportCoverageAllows(try frame(full, original: false), submissionID: covering.id))
            XCTAssertFalse(view.viewportCoverageAllows(try frame(full, scope: 2), submissionID: covering.id))
            XCTAssertFalse(view.viewportCoverageAllows(try frame(full, geometry: 2), submissionID: covering.id))
            view.mailbox.completed(covering.id)
            // Exercise the actual draw seam: a delayed narrow frame cannot acquire a drawable,
            // publish placement or enter the receipt-free compatibility fallback.
            var acquisitions = 0, placements = 0
            view.drawableAcquirer = { _ in acquisitions += 1; return nil }
            view.onFrameDrawn = { _ in placements += 1 }
            view.offer(crop); view.draw(in: view.metal)
            XCTAssertEqual(acquisitions, 0); XCTAssertEqual(placements, 0)
            XCTAssertEqual(view.fallbackCreationCount, 0); XCTAssertEqual(view.drawsPresented, 0)
            view.finishViewportCoverage(generation: 9, required: narrow.rect, retainEndpoint: true)
            XCTAssertFalse(view.viewportCoverageAllows(crop, submissionID: covering.id), "Old cleanup cannot shrink the current required area")
            view.finishViewportCoverage(generation: 10, required: full.rect, retainEndpoint: true)
            XCTAssertFalse(view.viewportCoverageAllows(crop, submissionID: covering.id), "Return endpoint must retain wide coverage")
            XCTAssertTrue(view.beginViewportCoverage(generation: 11, required: full.rect, scope: 1))
            coveringReceipt(ProcessInfo.processInfo.systemUptime)
            await drainReceiptQueue()
            XCTAssertFalse(view.viewportCoverageReady(generation: 11))
            view.finishViewportCoverage(generation: 11, required: narrow.rect, retainEndpoint: true)
            let current = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            XCTAssertTrue(view.viewportCoverageAllows(crop, submissionID: current.id), "Cancelled/zoom-in endpoint permits sharpening that covers its current pose")
            view.mailbox.completed(current.id)
            let terminalReceipt = try XCTUnwrap(view.viewportCoverageReceipt(crop))
            admission.lifetime.retire()
            terminalReceipt(ProcessInfo.processInfo.systemUptime)
            await drainReceiptQueue()
            XCTAssertFalse(view.viewportCoverageReady(generation: 11), "Retired source cannot reopen motion")
        }
    }
    @MainActor
    func testRetainedEndpointSurvivesUnchangedPoseAndRetiresForEveryManualPoseFamily() throws {
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.metal.isPaused = true
        var base = ViewportTransform(sourceSize: CGSize(width: 200, height: 100), canvasSize: CGSize(width: 100, height: 50), mode: .fit)
        base.setZoom(2, anchoredAt: CGPoint(x: 50, y: 25))
        let mutations: [(String, (inout ViewportTransform) -> Void)] = [
            ("map pan", { $0.pan(by: CGSize(width: 20, height: 0)) }),
            ("map jump", { $0.center(onSourcePoint: CGPoint(x: 180, y: 75)) }),
            ("zoom slider", { $0.setZoom(3, anchoredAt: CGPoint(x: 50, y: 25)) }),
            ("pointer/keyboard reveal", { let safe = $0.safeRect; _ = $0.reveal(sourcePoint: CGPoint(x: 190, y: 90), in: safe, margin: 8) }),
            ("safe insets", { $0.updateSafeInsets(ViewportInsets(top: 0, left: 0, bottom: 12, right: 0)) }),
            ("resize", { $0.resize(sourceSize: CGSize(width: 200, height: 100), canvasSize: CGSize(width: 120, height: 50)) })
        ]
        for (index, mutation) in mutations.enumerated() {
            let generation = UInt64(index + 1)
            XCTAssertTrue(view.beginViewportCoverage(generation: generation, required: base.visibleSourceRect, scope: 1))
            view.finishViewportCoverage(generation: generation, required: base.visibleSourceRect, retainEndpoint: true)
            var moved = base
            mutation.1(&moved)
            let rect = moved.visibleSourceRect
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
            let crop = CaptureRegion(epoch: 7, x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height), outputWidth: 64, outputHeight: 32)
            let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: admission.identity,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1),
                arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true,
                videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32), geometryEpoch: 1,
                    scopeEpoch: 1, ltrToken: nil, region: crop))
            view.mailbox.offer(envelope)
            let submitted = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            let before = view.viewportCoverageAllows(envelope, submissionID: submitted.id)
            view.synchronizeViewportCoverage(visible: base.visibleSourceRect)
            XCTAssertEqual(view.viewportCoverageAllows(envelope, submissionID: submitted.id), before,
                           "Unchanged endpoint/deferred observation must preserve the coverage policy")
            view.synchronizeViewportCoverage(visible: moved.visibleSourceRect)
            XCTAssertTrue(view.viewportCoverageAllows(envelope, submissionID: submitted.id), mutation.0 + " must admit its new legitimate crop")
            view.mailbox.completed(submitted.id)
        }
    }


    @MainActor
    func testDrawablePoolDefaultsToThreeTwoRestoresTheOldPoolAndIsFrozenPerRenderer() throws {
        let name = "OwnedVideoDrawablePool." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let original = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { original.invalidate() }
        XCTAssertEqual(original.drawablePoolCount, 3)
        XCTAssertEqual((original.metal.layer as? CAMetalLayer)?.maximumDrawableCount, 3)
        XCTAssertFalse(OwnedVideoPacingExperiment.diagnosticsEnabled(defaults: defaults))
        for invalid in [0, 1, 4, -1, 100] {
            defaults.set(invalid, forKey: OwnedVideoPacingExperiment.drawableCountKey)
            XCTAssertEqual(OwnedVideoPacingExperiment.drawableCount(defaults: defaults), 3)
        }
        defaults.set(2, forKey: OwnedVideoPacingExperiment.drawableCountKey)
        let restored = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { restored.invalidate() }
        XCTAssertEqual(restored.drawablePoolCount, 2)
        XCTAssertEqual((restored.metal.layer as? CAMetalLayer)?.maximumDrawableCount, 2)
        XCTAssertEqual(original.drawablePoolCount, 3, "changing defaults cannot mutate an existing drawable pool")
        defaults.removeObject(forKey: OwnedVideoPacingExperiment.drawableCountKey)
        XCTAssertEqual(OwnedVideoPacingExperiment.drawableCount(defaults: defaults), 3)
    }

    func testPacingWindowSeparatesWakeDrawsFromTicksAndBoundsAcquisitionEvidence() {
        var window = OwnedVideoPacingWindow()
        window.draw(.tick); window.draw(.sourceWake); window.draw(.tick)
        window.acquired(milliseconds: 0, available: true)
        window.acquired(milliseconds: 20, available: false)
        window.acquired(milliseconds: 1000 / 60, available: true)
        window.acquired(milliseconds: .nan, available: false)
        window.acquired(milliseconds: .infinity, available: false)
        window.acquired(milliseconds: -1, available: false)
        XCTAssertEqual(window.ticks, 2); XCTAssertEqual(window.sourceWakes, 1)
        XCTAssertEqual(window.acquisitions, 3); XCTAssertEqual(window.missingDrawables, 1)
        XCTAssertEqual(window.maximumAcquireMs, 20); XCTAssertEqual(window.waitsOverFrame, 1)
        XCTAssertEqual(window.meanAcquireMs, (20 + 1000 / 60) / 3, accuracy: 0.00001)
        window = OwnedVideoPacingWindow()
        XCTAssertEqual(window.acquisitions, 0); XCTAssertEqual(window.meanAcquireMs, 0)
        XCTAssertEqual(window.maximumAcquireMs, 0); XCTAssertEqual(window.ticks, 0)
        XCTAssertEqual(window.sourceWakes, 0); XCTAssertEqual(window.waitsOverFrame, 0)
    }

    func testSettledBackingPolicyHonorsRollbackAndBothOwnershipEdges() {
        let big = CGSize(width: 2560, height: 1600), small = CGSize(width: 1920, height: 1200)
        var enabled = OwnedVideoBackingPolicy(enabled: true)
        XCTAssertEqual(enabled.target(picture: small, current: big, at: 10, drained: false), big)
        XCTAssertEqual(enabled.target(picture: small, current: big, at: 11.99, drained: true), big)
        XCTAssertNil(enabled.target(picture: small, current: big, at: 12, drained: false))
        XCTAssertEqual(enabled.target(picture: small, current: big, at: 12, drained: true), small)
        XCTAssertEqual(enabled.target(picture: small, current: small, at: 20, drained: false), small)
        let grown = CGSize(width: 3000, height: 1875)
        XCTAssertNil(enabled.target(picture: grown, current: small, at: 21, drained: false))
        XCTAssertEqual(enabled.target(picture: grown, current: small, at: 21, drained: true), grown)
        var disabled = OwnedVideoBackingPolicy(enabled: false)
        for time in [0.0, 2.0, 30.0] {
            XCTAssertEqual(disabled.target(picture: small, current: big, at: time, drained: false), big)
        }
        XCTAssertEqual(disabled.target(picture: grown, current: small, at: 30, drained: false), grown)
    }

    func testBackingWobbleRestartsSettleAndRotationsStillUseExactAspect() {
        var policy = OwnedVideoBackingPolicy(enabled: true)
        let big = CGSize(width: 2560, height: 1600), small = CGSize(width: 1920, height: 1200)
        XCTAssertEqual(policy.target(picture: small, current: big, at: 10, drained: true), big)
        _ = policy.target(picture: CGSize(width: 1920, height: 1202), current: big, at: 11.9, drained: true)
        XCTAssertEqual(policy.target(picture: small, current: big, at: 12, drained: true), big)
        XCTAssertEqual(policy.target(picture: small, current: big, at: 14, drained: true), small)
        let rotated = CGSize(width: 1200, height: 1920)
        XCTAssertNil(policy.target(picture: rotated, current: small, at: 15, drained: false))
        XCTAssertEqual(policy.target(picture: rotated, current: small, at: 15, drained: true), rotated)
    }

    func testGeometrySwapWaitsForGPUAndPresentationInEitherOrder() throws {
        for gpuFirst in [true, false] {
            let box = NewestFrameMailbox<Int>()
            box.offer(1); let a = try XCTUnwrap(box.take(holdUntilPresented: true))
            box.offer(2); let b = try XCTUnwrap(box.take(holdUntilPresented: true))
            XCTAssertFalse(box.isOnlyFlight(b.id))
            if gpuFirst { box.gpuCompleted(a.id) } else { box.presented(a.id) }
            XCTAssertFalse(box.isOnlyFlight(b.id))
            if gpuFirst { box.presented(a.id) } else { box.gpuCompleted(a.id) }
            XCTAssertTrue(box.isOnlyFlight(b.id))
            box.invalidate(); XCTAssertFalse(box.isOnlyFlight(b.id))
        }
    }

    @MainActor
    func testPictureCandidatesDefaultOnAndPrecompiledPipelinesReuseDeviceCache() throws {
        let name = "OwnedVideoCandidates." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        func make() -> OwnedMetalVideoView {
            OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        }
        let unset = make(); defer { unset.invalidate() }
        XCTAssertTrue(unset.renderOptimizations.singleResample, "ON in the combined .7 device test")
        XCTAssertTrue(unset.renderOptimizations.precompiledShaders)
        defaults.set(false, forKey: "PocketDeskSingleResample")
        defaults.set(false, forKey: "PocketDeskPrecompiledShaders")
        let legacy = make(); defer { legacy.invalidate() }
        XCTAssertFalse(legacy.renderOptimizations.singleResample)
        XCTAssertFalse(legacy.renderOptimizations.precompiledShaders)
        defaults.set(true, forKey: "PocketDeskSingleResample")
        defaults.set(true, forKey: "PocketDeskPrecompiledShaders")
        let first = make(); defer { first.invalidate() }
        XCTAssertTrue(first.renderOptimizations.singleResample)
        XCTAssertTrue(first.renderOptimizations.precompiledShaders)
        XCTAssertFalse(legacy.renderOptimizations.singleResample, "the registered renderer's switches are immutable")
        let builds = OwnedMetalVideoView.precompiledPipelineBuilds
        XCTAssertGreaterThan(builds, 0, "the compiled library/pipelines must be available in the app bundle")
        let second = make(); defer { second.invalidate() }
        XCTAssertEqual(OwnedMetalVideoView.precompiledPipelineBuilds, builds)
        defaults.set(false, forKey: "PocketDeskSingleResample")
        defaults.set(false, forKey: "PocketDeskPrecompiledShaders")
        let restored = make(); defer { restored.invalidate() }
        XCTAssertFalse(restored.renderOptimizations.singleResample)
        XCTAssertFalse(restored.renderOptimizations.precompiledShaders)
    }

    @MainActor
    func testSmartZoomTracksEveryRedrawPresentationWithLegacyFenceSwitch() throws {
        let name = "OwnedVideoMixedRollback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneUnfencedDrawableDisabled")
        for singleResample in [false, true] {
            defaults.set(singleResample, forKey: "PocketDeskSingleResample")
            let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
            let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
            XCTAssertTrue(view.observesPresentation(isNew: true))
            XCTAssertTrue(view.observesPresentation(isNew: false), "A later Smart Zoom must drain redraws even with both optional preparation flags off")
            view.invalidate()
        }
    }

    func testDrawableWaitDiagnosticsAreBoundedAndReportTailsAndFallbackCreations() {
        let diagnostics = SmoothMotionDiagnostics()
        for i in 1...100 { diagnostics.drawableAcquisition(ms: Double(i)) }
        diagnostics.drawableAcquisition(ms: .nan)
        diagnostics.drawableAcquisition(ms: -1)
        diagnostics.rendererFallbackCreated()
        var result = diagnostics.snapshot()
        XCTAssertEqual(result.drawableWaitSamples, 100)
        XCTAssertEqual(result.drawableWaitP50Ms, 50)
        XCTAssertEqual(result.drawableWaitP95Ms, 95)
        XCTAssertEqual(result.drawableWaitMaxMs, 100)
        XCTAssertEqual(result.rendererFallbackCreations, 1)
        XCTAssertTrue(result.settingsLines.contains { $0.contains("Drawable wait:") && $0.contains("max 100.0 ms") })
        for _ in 0..<(SmoothMotionDiagnostics.sampleCapacity * 2) { diagnostics.drawableAcquisition(ms: 3) }
        result = diagnostics.snapshot()
        XCTAssertEqual(result.drawableWaitSamples, SmoothMotionDiagnostics.sampleCapacity)
        XCTAssertEqual(result.drawableWaitMaxMs, 3)
        diagnostics.reset(mode: .off)
        XCTAssertNil(diagnostics.snapshot().drawableWaitMaxMs)
        XCTAssertEqual(diagnostics.snapshot().rendererFallbackCreations, 0)
    }

    @MainActor
    func testDiagnosticsAttachmentIncludesFirstSourcePromptWaitAndFallback() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.drawRequester = { _ in }
        view.drawableAcquirer = { _ in nil }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        func offer() {
            view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
                arrivalMs: 1, marker: nil, originalSource: true, promptDraw: true))
            view.draw(in: view.metal)
        }
        offer() // No scheduled display tick/diagnostics attachment yet.
        CVBufferRemoveAttachment(buffer, kCVImageBufferTransferFunctionKey)
        offer() // Unsupported output color creates the compatibility view before attachment.
        XCTAssertEqual(view.fallbackCreationCount, 1)
        let diagnostics = SmoothMotionDiagnostics()
        view.renderDiagnostics = diagnostics
        XCTAssertEqual(diagnostics.snapshot().drawableWaitSamples, 1)
        XCTAssertEqual(diagnostics.snapshot().rendererFallbackCreations, 1)
        view.renderDiagnostics = diagnostics
        XCTAssertEqual(diagnostics.snapshot().drawableWaitSamples, 1, "repeated tick attachment cannot double count")
    }
    @MainActor
    func testOptInSingleResampleSettlesDownshiftWithoutChangingPinchBacking() throws {
        let name = "OwnedVideoSingleResample." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "PocketDeskSingleResample")
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { view.invalidate() }
        // A nil drawable is a resize/pressure retry, never permission to insert a black view.
        view.drawableAcquirer = { _ in nil }
        func offer(_ width: Int, _ height: Int) throws {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
                arrivalMs: 1, marker: nil, originalSource: true))
            view.draw(in: view.metal)
        }
        try offer(256, 160)
        try offer(192, 120)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 256, height: 160), "transient changes retain backing")
        RunLoop.current.run(until: Date().addingTimeInterval(2.05))
        try offer(192, 120)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 192, height: 120), "stable downshift eliminates decoded→larger drawable resampling")
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 750)
        view.setNeedsLayout(); view.layoutIfNeeded(); view.draw(in: view.metal)
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 192, height: 120), "pinch changes placement only")
    }

    @MainActor
    func testOptInDownshiftAndRotationSubmitEveryGeometryWithoutFallbackOnBothShaderPaths() throws {
        for compiled in [false, true] {
            let name = "OwnedVideoResizeDraw." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(true, forKey: "PocketDeskSingleResample")
            defaults.set(compiled, forKey: "PocketDeskPrecompiledShaders")
            let id = identity()
            let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
            let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
            defer { view.invalidate() }
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
            view.setNeedsLayout(); view.layoutIfNeeded()
            view.drawRequester = { _ in } // Drive the production draw path deterministically.
            func submit(_ width: Int, _ height: Int) throws {
                var pixels: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
                let buffer = try XCTUnwrap(pixels)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                let before = view.drawsPresented
                view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                    frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(before + 1)),
                    arrivalMs: 1, marker: nil, originalSource: true))
                for _ in 0..<200 {
                    view.draw(in: view.metal)
                    if view.drawsPresented > before { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                }
                XCTAssertEqual(view.drawsPresented, before + 1, "every geometry submits a picture, compiled=\(compiled)")
            }
            try submit(256, 160)
            try submit(192, 120)
            XCTAssertEqual(view.metal.drawableSize, CGSize(width: 256, height: 160))
            RunLoop.current.run(until: Date().addingTimeInterval(2.05))
            try submit(192, 120)
            XCTAssertEqual(view.metal.drawableSize, CGSize(width: 192, height: 120))
            try submit(120, 192)
            XCTAssertEqual(view.metal.drawableSize, CGSize(width: 120, height: 192))
            XCTAssertEqual(view.fallbackCreationCount, 0)
            // Command submissions and simulator GPU completion cannot prove physical no-blank presentation.
        }
    }
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
    @MainActor
    func testMailboxWakeOnReleaseDrawsAWaitingFrameOnceBothSlotEdgesFreeOnlyWithTheSwitch() async throws {
        let name = "OwnedVideoWakeOnRelease." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        func envelope(_ stamp: Int64) -> VideoFrameEnvelope {
            VideoFrameEnvelope(receiptID: UUID(), identity: admission.identity,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: stamp),
                arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true, promptDraw: true)
        }
        func drainMain() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        func requestsAfterRelease(switchOn: Bool) async throws -> Int {
            defaults.set(switchOn ? "YES" : nil, forKey: MailboxWakeOnReleaseSwitch.defaultsKey)
            let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
            defer { view.drawRequester = { $0.draw() }; view.invalidate() }
            view.metal.isPaused = true
            var requests = 0
            view.drawRequester = { _ in requests += 1 }
            view.mailbox.offer(envelope(1)); let first = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            view.mailbox.offer(envelope(2)); let second = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
            view.offer(envelope(3)); await drainMain()
            XCTAssertEqual(requests, 1, "the arrival wake runs as before and finds both slots owned")
            XCTAssertTrue(view.mailbox.hasPending); XCTAssertFalse(view.mailbox.pendingAdmissible)
            view.flightReleased(); view.mailbox.gpuCompleted(first.id); view.flightReleased(); await drainMain()
            XCTAssertEqual(requests, 1, "GPU completion alone frees no slot")
            view.mailbox.presented(first.id)
            XCTAssertTrue(view.mailbox.pendingAdmissible)
            view.flightReleased(); await drainMain()
            view.mailbox.completed(second.id)
            return requests
        }
        let on = try await requestsAfterRelease(switchOn: true)
        XCTAssertEqual(on, 2, "a freed slot draws the waiting frame at once")
        let off = try await requestsAfterRelease(switchOn: false)
        XCTAssertEqual(off, 1, "off, the frame waits for the next tick as today")
        let box = NewestFrameMailbox<Int>()
        box.offer(1); let a = try XCTUnwrap(box.take(holdUntilPresented: true))
        box.offer(2); _ = try XCTUnwrap(box.take(holdUntilPresented: true))
        var refused = false
        XCTAssertNil(box.take(redraw: false, holdUntilPresented: true, refused: &refused)); XCTAssertFalse(refused, "nothing pending is not a refusal")
        box.offer(3)
        XCTAssertNil(box.take(redraw: false, holdUntilPresented: true, refused: &refused)); XCTAssertTrue(refused)
        refused = false
        XCTAssertNil(box.take(redraw: false, holdUntilPresented: true, refused: &refused)); XCTAssertFalse(refused, "one refusal per waiting frame")
        box.offer(4)
        XCTAssertNil(box.take(redraw: false, holdUntilPresented: true, refused: &refused)); XCTAssertTrue(refused, "a newer waiting frame is refused once more")
        box.completed(a.id); refused = false
        XCTAssertEqual(try XCTUnwrap(box.take(redraw: false, holdUntilPresented: true, refused: &refused)).frame, 4); XCTAssertFalse(refused)
    }
    func testPresentedReceiptRecordsCommitToGlassAndCountsADroppedDrawableOnce() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        let counters = StreamCounters(phoneRenderTimingEnabled: true)
        view.counters = counters
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true)
        let stamp = PresentationStamp(); stamp.commitMs = 1_000
        view.presentedReceipt(envelope, commit: stamp, callback: nil)(1.02)
        view.presentedReceipt(envelope, commit: stamp, callback: nil)(0)
        view.presentedReceipt(envelope, commit: nil, callback: nil)(1.03)
        let drained = expectation(description: "receipt queue drained")
        OwnedMetalVideoView.presentedReceiptQueue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.commitToPresentedSamples, 1, "no commit stamp, no commit→glass sample")
        XCTAssertEqual(snapshot.commitToPresentedP50Ms ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentedDropped, 1)
        XCTAssertEqual(snapshot.presentedIntervalP50Ms ?? 0, 10, accuracy: 0.001, "the dropped drawable adds no interval")
    }
    @MainActor
    func testMetalDisplayLinkPresenterDrawsIntoTheLinkDrawableAndNeverAsksMTKViewToDraw() async throws {
        let name = "OwnedVideoMetalDisplayLink." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let plain = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { plain.invalidate() }
        XCTAssertFalse(plain.presentsThroughDisplayLink); XCTAssertFalse(plain.metal.isPaused)
        defaults.set("YES", forKey: MetalDisplayLinkSwitch.defaultsKey)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { view.drawRequester = { $0.draw() }; view.invalidate() }
        XCTAssertTrue(view.presentsThroughDisplayLink); XCTAssertTrue(view.metal.isPaused); XCTAssertFalse(view.metal.enableSetNeedsDisplay)
        let linkLayer = try XCTUnwrap(view.metal.layer as? CAMetalLayer)
        XCTAssertEqual(linkLayer.drawableSize, CGSize(width: 1, height: 1), "a paused MTKView never sizes its layer; a 0×0 layer gets no link callbacks")
        view.displayLinkPaused = true // This test hands the drawables out itself.
        var requests = 0
        view.drawRequester = { _ in requests += 1 }
        var drawn: [VideoFrameEnvelope] = []
        view.onFrameDrawn = { drawn.append($0) }
        view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        view.setNeedsLayout(); view.layoutIfNeeded()
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: admission.identity,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true, promptDraw: true)
        view.offer(envelope)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(requests, 0, "a pass-through arrival waits for the next link callback; no out-of-band draw")
        XCTAssertEqual(view.metal.preferredFramesPerSecond, 60, "no window yet: the link is clamped to a 60 Hz panel")
        // Core Animation refuses `nextDrawable` on the link's own layer, so stand-in layers supply the drawables
        // the link would hand to the callback.
        var layers: [CAMetalLayer] = []
        func drawable(_ edge: CGFloat) throws -> CAMetalDrawable {
            let layer = CAMetalLayer()
            layer.device = view.metal.device; layer.pixelFormat = view.metal.colorPixelFormat
            layer.drawableSize = CGSize(width: edge, height: edge); layers.append(layer)
            return try XCTUnwrap(layer.nextDrawable())
        }
        view.drawLinkFrame(into: try drawable(1))
        XCTAssertEqual(view.drawsPresented, 0); XCTAssertTrue(view.mailbox.hasPending, "a drawable of the old size requeues the frame")
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(linkLayer.drawableSize, CGSize(width: 64, height: 64), "the link's next drawable must have the new size")
        view.drawLinkFrame(into: try drawable(64))
        XCTAssertEqual(view.fallbackCreationCount, 0, "the picture went into the link's drawable, not the compatibility view")
        XCTAssertEqual(view.drawsPresented, 1); XCTAssertEqual(drawn.count, 1); XCTAssertFalse(view.mailbox.hasPending)
        view.drawLinkFrame(into: try drawable(64))
        XCTAssertEqual(view.drawsPresented, 1, "an empty callback leaves its drawable untouched")
        XCTAssertEqual(requests, 0)
        view.offer(envelope)
        view.draw(in: view.metal)
        XCTAssertEqual(view.drawsPresented, 1, "a draw without a link drawable never asks the link's layer for one")
        XCTAssertTrue(view.mailbox.hasPending, "the frame waits for the next callback instead")
        view.invalidate(); view.invalidate() // Then the deferred invalidate and dealloc: the link is torn down exactly once.
        XCTAssertFalse(view.presentsThroughDisplayLink)
        // An admission that expires mid-session invalidates from inside the link's own callback.
        let brief = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 0.05)
        let expiring = OwnedMetalVideoView(admission: brief, fence: VideoPresentationFence(brief), defaults: defaults)
        expiring.displayLinkPaused = true
        XCTAssertTrue(expiring.presentsThroughDisplayLink)
        try await Task.sleep(for: .milliseconds(80))
        expiring.drawLinkFrame(into: try drawable(64))
        XCTAssertFalse(expiring.presentsThroughDisplayLink, "the expired fence tore the link down from its callback")
        XCTAssertTrue(expiring.metal.isHidden)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    /// The real link, in a window: its callbacks arrive and draw. Without this the presenter showed nothing on an
    /// iPhone 17 (9 Oct 2026) while every test that handed drawables in by hand passed.
    @MainActor
    func testMetalDisplayLinkCallsBackInAWindowAndDrawsAnOfferedFrame() async throws {
        let name = "OwnedVideoMetalDisplayLinkLive." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("YES", forKey: MetalDisplayLinkSwitch.defaultsKey)
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission), defaults: defaults)
        defer { view.invalidate() }
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "a display link needs a foreground test host")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 200, height: 200); window.isHidden = false
        defer { window.isHidden = true }
        view.frame = window.bounds; window.addSubview(view); view.layoutIfNeeded()
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        view.offer(VideoFrameEnvelope(receiptID: UUID(), identity: admission.identity,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true, promptDraw: true))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while view.drawsPresented == 0, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(view.linkCallbacks, 0, "the link called back")
        XCTAssertGreaterThanOrEqual(view.drawsPresented, 1, "the frame reached a link drawable")
        XCTAssertEqual(view.metal.drawableSize, CGSize(width: 64, height: 48))
        XCTAssertEqual((view.metal.layer as? CAMetalLayer)?.drawableSize, CGSize(width: 64, height: 48))
        XCTAssertEqual(view.fallbackCreationCount, 0)
    }
    func testLinkDiagnosticsWindowCountsOutcomesInDeclarationOrder() {
        var window = LinkDiagnosticsWindow()
        window.record(.drawableSizeStale); window.record(.drawn); window.record(.nothingPending); window.record(.nothingPending)
        XCTAssertEqual(window.callbacks, 4); XCTAssertEqual(window.count(.nothingPending), 2)
        XCTAssertEqual(window.summary, "drawn 1, nothingPending 2, drawableSizeStale 1")
    }
    func testTheLinkRateFollowsThePanelLowPowerModeAndASixtyHertzIdleFloor() {
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 120, panelMaximum: 120, lowPower: false, idle: false), 120)
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 120, panelMaximum: 60, lowPower: false, idle: false), 60)
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 120, panelMaximum: 120, lowPower: true, idle: false), 60)
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 120, panelMaximum: 120, lowPower: false, idle: true), 60,
                       "idle waits at most one 60 Hz tick, not MTKView's 30 Hz")
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 60, panelMaximum: 120, lowPower: false, idle: false), 60)
        XCTAssertEqual(OwnedMetalVideoView.linkRate(active: 60, panelMaximum: 120, lowPower: true, idle: true), 60)
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
