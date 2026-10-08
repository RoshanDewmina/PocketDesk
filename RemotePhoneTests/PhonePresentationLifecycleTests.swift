import XCTest
import AVKit
import SwiftUI
import UIKit
import WebRTC
@testable import PocketDeskRemote

private final class PresentationLifecyclePiPPlatform: LivePiPPlatformController {
    var nativeController: AVPictureInPictureController? { nil }
    var isPossible: Bool { true }
    private(set) var starts = 0
    func start() { starts += 1 }
    func stop() {}
    func invalidatePlaybackState() {}
    func detachDelegate() {}
}

final class PhonePresentationLifecycleTests: XCTestCase {
    private func identity(geometry: UInt64 = 7, content: UInt64 = 1, track: UUID = UUID(), grant: String = "grant") -> VideoPresentationIdentity {
        VideoPresentationIdentity(hostRecordID: "record", ownerPairID: grant, sessionID: UUID(),
            trackID: track, contentEpoch: content, geometryEpoch: geometry)
    }
    @MainActor
    func testRealModelExitTimeoutSurvivesGeometryRetirementAndRoutineStatus() throws {
        // Actual downstream state machine, finite source proof and injected platform;
        // this test neither constructs native AVKit nor proves a network producer.
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let platform = PresentationLifecyclePiPPlatform()
        let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in platform })
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip)
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "pip-exit")
        defer { model.connection.stop() }
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
        model.stopPictureInPicture()
        XCTAssertFalse(packets.contains { $0.action.action == "viewOnly" }, "No exit is owed before any enter")
        _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        model.sendViewOnlyEntryForTesting()
        let enter = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == true })
        try deliver(RemoteAction(action: "capture", liveViewOnly: true, liveViewOnlyRequestID: enter.action.liveViewOnlyRequestID,
                                x: 1, epoch: 7, features: [SessionFeature.liveViewOnly], mode: "picture"))
        XCTAssertEqual(platform.starts, 1)
        pip.confirmPlatformStartForTesting(platform)
        XCTAssertEqual(model.pipState, .active)
        XCTAssertTrue(model.viewOnlyConfirmedForTesting)
        model.stopPictureInPicture()
        let exit = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false })
        XCTAssertFalse(exit.action.liveViewOnly ?? true)
        XCTAssertNotNil(exit.action.liveViewOnlyRequestID)
        let originalDeadline = try XCTUnwrap(model.viewOnlyExitDeadlineForTesting)
        model.stopPictureInPicture(); model.stopPictureInPicture()
        XCTAssertEqual(model.viewOnlyExitDeadlineForTesting, originalDeadline, "Repeated cleanup cannot extend the original bound")
        // Host drops old-geometry exit; a new geometry cannot reuse its cleanup ACK.
        try deliver(RemoteAction(action: "geometry", x: 210, y: 200, epoch: 8))
        try deliver(RemoteAction(action: "capture", liveViewOnly: true, x: 1, epoch: 8, features: [SessionFeature.liveViewOnly], mode: "picture"))
        try deliver(RemoteAction(action: "capture", liveViewOnly: false, x: 1, epoch: 8, features: [SessionFeature.liveViewOnly], mode: "picture"))
        try deliver(RemoteAction(action: "capture", liveViewOnly: false, liveViewOnlyRequestID: exit.action.liveViewOnlyRequestID,
                                x: 1, epoch: 8, features: [SessionFeature.liveViewOnly], mode: "picture"))
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting, "Even the exact old ID cannot satisfy a different geometry")
        XCTAssertEqual(model.viewOnlyExitDeadlineForTesting, originalDeadline)
        XCTAssertTrue(model.connection.connected, "Routine state is not an applied exit acknowledgment")
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 3)
        XCTAssertFalse(model.connection.connected, "Retirement must never erase the bounded foreground exit timeout")
    }
    @MainActor
    func testActualQueuedEnterRetirementKeepsHostSuspensionCleanupBounded() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "pip-enter")
        defer { model.connection.stop() }
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
        model.sendViewOnlyEntryForTesting() // Production transaction after the public PiP admission guard.
        XCTAssertEqual(packets.last { $0.action.action == "viewOnly" }?.action.liveViewOnly, true)
        try deliver(RemoteAction(action: "geometry", x: 220, y: 200, epoch: 8))
        let deadline = try XCTUnwrap(model.viewOnlyExitDeadlineForTesting)
        try deliver(RemoteAction(action: "capture", liveViewOnly: true, x: 0, epoch: 8, features: SessionFeature.host, mode: "picture"))
        model.expireViewOnlyExitForTesting(at: deadline - 0.2)
        model.expireViewOnlyExitForTesting(at: deadline - 0.1)
        XCTAssertEqual(model.viewOnlyExitDeadlineForTesting, deadline)
        model.expireViewOnlyExitForTesting(at: deadline + 0.01)
        XCTAssertFalse(model.connection.connected)
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
    /// Frozen PiP 1 Oct: iOS refuses a background app's GPU work, so the GPU CIContext conversion stopped producing
    /// frames once Farside left the screen. The sink renders on the CPU while backgrounded and back on the GPU after.
    func testBackgroundPiPFramesRenderOnTheCPU() {
        let admission = VideoPresentationAdmission(identity: identity(), validUntil: ProcessInfo.processInfo.systemUptime + 10)
        let center = NotificationCenter()
        let sink = LivePiPSampleBufferSink(admission: admission, fence: VideoPresentationFence(admission), center: center)
        defer { sink.invalidate() }
        sink.setBackground(false)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(sink.rendersInSoftware)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertFalse(sink.rendersInSoftware)
    }
    /// Frozen PiP 1 Oct: the Mac's ladder resized the stream (1920x1232 <-> 2560x1656) inside one identity, and the
    /// sink refused every frame of a new size for the rest of the session. A resize now replaces the output pool.
    func testPiPSinkKeepsEnqueueingAfterTheStreamChangesSize() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let sink = LivePiPSampleBufferSink(admission: admission, fence: VideoPresentationFence(admission), center: NotificationCenter())
        defer { sink.invalidate() }
        sink.setEnabled(true)
        func offer(width: Int, height: Int) throws {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                               [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            sink.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
                frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._90, timeStampNs: 1),
                arrivalMs: 1, marker: nil, originalSource: true)) // Rotated: exercises the conversion pool, not the direct path.
        }
        func waitFor(_ count: Int) {
            let deadline = Date().addingTimeInterval(3)
            while sink.enqueued < count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        try offer(width: 64, height: 40); waitFor(1)
        XCTAssertEqual(sink.enqueued, 1)
        try offer(width: 96, height: 60); waitFor(2)
        XCTAssertEqual(sink.enqueued, 2, "a resized stream keeps reaching the PiP window")
        sink.setBackground(true)
        try offer(width: 64, height: 40); waitFor(3)
        XCTAssertEqual(sink.enqueued, 3, "the CPU path also converts and enqueues")
    }
    /// Jittery PiP 1 Oct 18:1x: every frame went through Core Image (on the CPU in the background). Decoded frames
    /// the layer can show as they are now skip the conversion.
    func testPiPSinkHandsDecodedFramesStraightToTheLayer() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let sink = LivePiPSampleBufferSink(admission: admission, fence: VideoPresentationFence(admission), center: NotificationCenter())
        defer { sink.invalidate() }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true)
        let decoded = try XCTUnwrap(envelope.pixels)
        XCTAssertTrue(LivePiPSampleBufferSink.displaysDirectly(decoded, rotation: 0))
        XCTAssertFalse(LivePiPSampleBufferSink.displaysDirectly(decoded, rotation: 90), "rotation still converts")
        sink.offer(envelope)
        let deadline = Date().addingTimeInterval(3)
        while sink.enqueued < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(sink.enqueued, 1)
        XCTAssertEqual(sink.directCount, 1, "no per-frame conversion")
    }
    func testBackgroundRequiresActualActivePiPAndHostAppliedConfirmation() {
        let proof = VideoPresentationAdmission(identity: identity(), validUntil: 12)
        for state in [LivePiPPolicy.State.ready, .starting, .paused, .stopping, .ineligible] {
            XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: state, admission: proof, viewOnlyConfirmed: true, now: 11))
        }
        XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: false, now: 11))
        XCTAssertFalse(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: true, now: 12))
        XCTAssertTrue(PresentationLeasePolicy.mayContinueBackground(state: .active, admission: proof, viewOnlyConfirmed: true, now: 11))
        for state in [LivePiPPolicy.State.active, .paused] {
            XCTAssertTrue(PresentationLeasePolicy.mayHoldBackground(state: state, admission: proof, viewOnlyConfirmed: true, now: 11))
            XCTAssertFalse(PresentationLeasePolicy.mayHoldBackground(state: state, admission: proof, viewOnlyConfirmed: false, now: 11))
            XCTAssertFalse(PresentationLeasePolicy.mayHoldBackground(state: state, admission: proof, viewOnlyConfirmed: true, now: 12))
        }
        for state in [LivePiPPolicy.State.ready, .starting, .stopping, .ineligible] {
            XCTAssertFalse(PresentationLeasePolicy.mayHoldBackground(state: state, admission: proof, viewOnlyConfirmed: true, now: 11))
        }
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

final class LiveCanvasHitTestTests: XCTestCase {
    @MainActor
    private func trackpad(in view: UIView) -> NativeTrackpadInputView? {
        if let pad = view as? NativeTrackpadInputView { return pad }
        for sub in view.subviews { if let pad = trackpad(in: sub) { return pad } }
        return nil
    }
    @MainActor
    private func describe(_ view: UIView?) -> String {
        var chain: [String] = []; var current = view
        while let v = current { chain.append("\(type(of: v)) ui=\(v.isUserInteractionEnabled) f=\(v.frame.integral)"); current = v.superview }
        return chain.joined(separator: " <- ")
    }
    @MainActor
    func testLiveSessionCanvasCenterHitsTrackpad() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "canvas-hit")
        defer { model.connection.stop() }
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.onAuthenticated?()
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 1920, y: 1243, epoch: 7))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 7, features: SessionFeature.host + [SessionFeature.away], mode: "picture"))
        let host = UIHostingController(rootView: PhoneRemoteView(model: model, connection: model.connection))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.view.layoutIfNeeded()
        let pad = try XCTUnwrap(trackpad(in: host.view), "Session view never mounted the trackpad")
        let center = pad.convert(CGPoint(x: pad.bounds.midX, y: pad.bounds.midY), to: window)
        let hit = window.hitTest(center, with: nil)
        print("CANVAS-HIT pad=\(pad.frame) hit=\(describe(hit))")
        XCTAssertTrue(hit === pad, "Canvas center must reach the trackpad; got \(describe(hit))")
    }

    @MainActor
    func testPhoneTypingClaimsStayActiveUntilEveryOwnerLetsGo() {
        let claims = PhoneTypingClaims(), browser = UUID(), picker = UUID()
        claims.set(false, owner: browser)
        XCTAssertFalse(claims.active)
        claims.set(true, owner: browser); claims.set(true, owner: picker); claims.set(true, owner: picker)
        XCTAssertTrue(claims.active)
        claims.set(false, owner: picker)
        XCTAssertTrue(claims.active, "The folder browser is still open")
        claims.set(false, owner: browser)
        XCTAssertFalse(claims.active)
    }

    /// A phone sheet with a text field (the Mac folder browser's filter) keeps the typing: the canvas
    /// stops forwarding keys and stops re-taking first responder on session updates, then resumes.
    @MainActor
    func testPhoneTypingSheetKeepsKeysOnThePhoneUntilItCloses() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "phone-typing")
        defer { model.connection.stop() }
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.onAuthenticated?()
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 1920, y: 1243, epoch: 7))
        let status = RemoteAction(action: "capture", x: 1, epoch: 7, features: SessionFeature.host + [SessionFeature.away], mode: "picture")
        try deliver(status)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 7))
        model.frameReceived()
        XCTAssertTrue(model.canControl, "The fixture grants control")
        XCTAssertFalse(PhoneTypingClaims.shared.active, "No earlier test left a claim behind")
        let host = UIHostingController(rootView: PhoneRemoteView(model: model, connection: model.connection).environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        model.frameReceived()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let pad = try XCTUnwrap(trackpad(in: host.view), "Session view never mounted the trackpad")
        XCTAssertTrue(model.canControl)
        XCTAssertTrue(pad.hardwareKeys, "A controllable live session sends keys to the Mac")
        XCTAssertTrue(pad.isFirstResponder, "The canvas holds keyboard focus before the sheet opens")

        let sheet = UIHostingController(rootView: Color.clear.ownsPhoneTyping())
        let field = UITextField(frame: CGRect(x: 20, y: 80, width: 200, height: 44))
        sheet.view.addSubview(field)
        host.present(sheet, animated: false)
        defer { if host.presentedViewController != nil { host.dismiss(animated: false) } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(PhoneTypingClaims.shared.active)
        XCTAssertFalse(pad.hardwareKeys, "Keys typed into the sheet never reach the Mac")
        XCTAssertNil(pad.keyCommands, "Escape and ⌘W stay with the sheet")
        XCTAssertTrue(field.becomeFirstResponder())
        for _ in 0..<3 {
            model.objectWillChange.send()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(field.isFirstResponder, "Session updates must not take focus back from the sheet's field")
        XCTAssertFalse(pad.isFirstResponder)

        host.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try deliver(status); model.frameReceived()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(PhoneTypingClaims.shared.active)
        XCTAssertTrue(pad.hardwareKeys, "Keys go to the Mac again once the sheet closes")
        XCTAssertTrue(pad.isFirstResponder, "The canvas takes keyboard focus back")
    }
}
