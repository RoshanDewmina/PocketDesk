import XCTest
import AVKit
import SwiftUI
import UIKit
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
}
