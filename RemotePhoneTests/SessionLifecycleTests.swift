import XCTest
import SwiftUI
import Combine
import AVKit
import CoreVideo
import WebRTC
@testable import PocketDeskRemote

@MainActor
final class FakeBackgroundExecution: BackgroundExecution {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var isActive = false
    var granted = true
    var remainingTime: TimeInterval? = 29

    func begin(onExpiration: @escaping @MainActor () -> Void) -> Bool {
        begins += 1
        isActive = granted
        return granted
    }

    func end() {
        if isActive { ends += 1 }
        isActive = false
    }
}


private final class LifecyclePiPPlatform: LivePiPPlatformController {
    var nativeController: AVPictureInPictureController? { nil }
    var isPossible: Bool { true }
    private(set) var starts = 0
    func start() { starts += 1 }
    func stop() {}
    func invalidatePlaybackState() {}
    func detachDelegate() {}
}

@MainActor
final class SessionLifecycleTests: XCTestCase {
    func testViewportTransitionRejectsPointerInputKeepsKeysAndIgnoresOldCompletion() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(),
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "smart-zoom-input-fence")
        var sent: [RemoteAction] = []
        model.connection.inputPacketSenderForTesting = { sent.append($0.action); return true }
        defer { model.connection.stop() }
        func deliver(_ action: RemoteAction) throws {
            try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(action))
        }
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 3))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 3, features: [SessionFeature.absolutePointer]))
        model.frameReceived()
        XCTAssertTrue(model.canControl)
        let first = model.beginViewportTransition()
        sent.removeAll()
        XCTAssertFalse(model.pointTo(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(model.gesture(.click(count: 1)))
        XCTAssertFalse(model.gesture(.move(CGSize(width: 10, height: 0))))
        XCTAssertFalse(model.gesture(.secondaryClick))
        XCTAssertTrue(model.hardwareKey("a", modifiers: []))
        XCTAssertEqual(sent.map(\.action), ["key"], "Blocked pointer commands are discarded, not queued")
        let second = model.beginViewportTransition()
        model.endViewportTransition(first)
        XCTAssertTrue(model.coordinateInputFenced, "An earlier completion cannot reopen a newer transition")
        XCTAssertFalse(model.gesture(.click(count: 1)))
        model.endViewportTransition(second)
        XCTAssertTrue(model.gesture(.click(count: 1)))
        XCTAssertEqual(sent.filter { $0.action == "click" }.count, 1)
    }

    func testGeometryAndEndRetireViewportTransitionBeforeLateCompletion() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(),
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.connection.startInputFixtureForTesting(session: "smart-zoom-retirement")
        model.connection.inputPacketSenderForTesting = { _ in true }
        defer { model.connection.stop() }
        let old = model.beginViewportTransition()
        try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(RemoteAction(action: "geometry", x: 1440, y: 900, epoch: 4)))
        XCTAssertFalse(model.coordinateInputFenced)
        let current = model.beginViewportTransition()
        model.endViewportTransition(old)
        XCTAssertEqual(model.viewportTransitionGeneration, current)
        model.connection.onEnded?()
        XCTAssertFalse(model.coordinateInputFenced)
        model.endViewportTransition(current)
        XCTAssertFalse(model.coordinateInputFenced)
    }

    #if FARSIDE_WORKSPACE_BETA
    func testVoiceBlockedSmartZoomStartAndCancelledTaskCleanupCannotOrphanOrReplaceFence() async throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(),
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "smart-zoom-voice-guard")
        model.connection.inputPacketSenderForTesting = { _ in true }
        defer { model.connection.stop() }
        XCTAssertNil(model.beginSmartZoomTransition(interactionBlocked: true), "Open Dictate/Controls must reject before acquiring a fence")
        XCTAssertFalse(model.coordinateInputFenced)
        let first = try XCTUnwrap(model.beginSmartZoomTransition(interactionBlocked: false))
        let started = expectation(description: "transition suspended")
        let task = Task { @MainActor in
            defer { model.finishSmartZoomTransition(first, visible: CGRect(x: 0, y: 0, width: 100, height: 100)) }
            started.fulfill()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await task.value
        XCTAssertFalse(model.coordinateInputFenced, "Cancelled await must execute owner cleanup without normal completion")
        let next = try XCTUnwrap(model.beginSmartZoomTransition(interactionBlocked: false))
        XCTAssertNil(model.beginSmartZoomTransition(interactionBlocked: true))
        model.finishSmartZoomTransition(first, visible: .zero)
        XCTAssertEqual(model.viewportTransitionGeneration, next, "Older cleanup and blocked starts cannot disturb a newer owner")
        model.finishSmartZoomTransition(next, visible: .zero)
        XCTAssertFalse(model.coordinateInputFenced)
        model.sceneChanged(.inactive)
        XCTAssertNil(model.beginSmartZoomTransition(interactionBlocked: false), "Lifecycle-invalid starts must not acquire a fence")
    }

    func testBetaReadyRequiresMatchingOriginalRasterLifetimeAndAppliedLocalGeometry() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(),
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()), deviceIdiom: .phone)
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "phone-workspace-presented-ready")
        model.connection.inputPacketSenderForTesting = { _ in true }
        defer { model.connection.stop() }
        func deliver(_ action: RemoteAction) throws { try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(action)) }
        let features = [SessionFeature.phoneWorkspaceBeta, SessionFeature.virtualDisplay]
        try deliver(RemoteAction(action: "geometry", x: 1440, y: 900, epoch: 7))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 7))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 7, features: features, display: 9,
            virtualDisplayActive: false, virtualDisplayPhase: .idle,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
        XCTAssertTrue(model.enterBetaWorkspace())
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewportUnavailable, "Waiting for first measurement is not cancellation")
        model.virtualDisplayViewportChanged(size: CGSize(width: 380, height: 240), scale: 3, maximumFPS: 60,
            generation: model.workspaceMeasurementGeneration)
        try deliver(RemoteAction(action: "geometry", x: 570, y: 360, epoch: 8))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 8))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 8, features: features, display: 9,
            virtualDisplayActive: true, virtualDisplayPhase: .active,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
        model.frameReceived()
        _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        let admission = try XCTUnwrap(model.inlinePresentationAdmission)
        func source(width: Int, height: Int, lifetime: VideoPresentationLifetime, original: Bool = true,
                    lease: VideoPresentationAdmission? = nil, tagGeometry: UInt64 = 8,
                    presentedAt: TimeInterval? = nil) throws -> VideoPresentedSource {
            let current = lease ?? admission
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1)
            return .init(lifetime: lifetime, envelope: .init(receiptID: UUID(), identity: current.identity,
                frame: frame, arrivalMs: 1, marker: nil, originalSource: original,
                videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
                    geometryEpoch: tagGeometry, scopeEpoch: 3, ltrToken: nil)),
                presentedAt: presentedAt ?? ProcessInfo.processInfo.systemUptime, refinementPixels: nil)
        }
        model.rotationSourcePresented(try source(width: 1140, height: 720, lifetime: admission.lifetime))
        XCTAssertFalse(model.workspaceBetaReady, "Model geometry alone cannot replace applied native layout")
        model.workspaceGeometryApplied(source: model.sourceSize, generation: model.workspaceMeasurementGeneration)
        model.rotationSourcePresented(try source(width: 128, height: 256, lifetime: admission.lifetime))
        XCTAssertFalse(model.workspaceBetaReady, "A different raster cannot prove the fitted source")
        model.rotationSourcePresented(try source(width: 1140, height: 720, lifetime: admission.lifetime, original: false))
        XCTAssertFalse(model.workspaceBetaReady, "Interpolation is not a fitted original-source receipt")
        let retired = VideoPresentationLifetime(); retired.retire()
        model.rotationSourcePresented(try source(width: 1140, height: 720, lifetime: retired))
        XCTAssertFalse(model.workspaceBetaReady, "A queued retired renderer cannot prove readiness")
        model.rotationSourcePresented(try source(width: 1140, height: 720, lifetime: admission.lifetime))
        XCTAssertTrue(model.workspaceBetaReady)
        XCTAssertTrue(model.canControl)
        let retainedWorkspace = try source(width: 1140, height: 720, lifetime: admission.lifetime)
        model.exitBetaWorkspace()
        XCTAssertFalse(model.workspaceBetaReady)
        XCTAssertTrue(model.workspaceBetaExitPending)
        for phase: WorkspaceBetaPhase in [.restoring, .blocked] {
            try deliver(RemoteAction(action: "capture", x: 1, epoch: 8, features: features, display: 9,
                virtualDisplayActive: true, virtualDisplayPhase: phase,
                captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
            model.rotationSourcePresented(retainedWorkspace)
            XCTAssertTrue(model.workspaceBetaExitPending, "Retained Workspace pixels cannot finish restoration")
            XCTAssertFalse(model.canControl)
        }
        // Confirm a new ordinary geometry and explicit feature withdrawal. Status alone cannot
        // prove that the ordinary picture has physically reached this renderer.
        try deliver(RemoteAction(action: "geometry", x: 1440, y: 900, epoch: 9))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 9))
        let ordinaryFeatures = [SessionFeature.displayScale, SessionFeature.captureScope]
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 9, features: ordinaryFeatures, display: 1,
            virtualDisplayActive: false, virtualDisplayPhase: .idle,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
        model.frameReceived()
        XCTAssertFalse(model.hostFeatures.contains(SessionFeature.virtualDisplay))
        XCTAssertFalse(model.virtualDisplayActive)
        XCTAssertTrue(model.workspaceBetaExitPending)
        _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        let ordinary = try XCTUnwrap(model.inlinePresentationAdmission)
        let currentOrdinary = try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            lease: ordinary, tagGeometry: 9)
        model.rotationSourcePresented(currentOrdinary)
        XCTAssertTrue(model.workspaceBetaExitPending, "Current model geometry does not acknowledge native layout")
        model.workspaceGeometryApplied(source: model.sourceSize, generation: model.workspaceMeasurementGeneration)
        model.rotationSourcePresented(retainedWorkspace)
        XCTAssertTrue(model.workspaceBetaExitPending, "A retired old renderer cannot finish the new ordinary route")
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            lease: ordinary, tagGeometry: 8))
        XCTAssertTrue(model.workspaceBetaExitPending, "A current renderer carrying an old geometry tag is stale")
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            lease: ordinary, tagGeometry: 9, presentedAt: ProcessInfo.processInfo.systemUptime - 1))
        XCTAssertTrue(model.workspaceBetaExitPending, "An old physical receipt cannot declare the current picture ready")
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: retired,
            lease: ordinary, tagGeometry: 9))
        XCTAssertTrue(model.workspaceBetaExitPending, "Even matching identity cannot revive a retired lifetime")
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            original: false, lease: ordinary, tagGeometry: 9))
        XCTAssertTrue(model.workspaceBetaExitPending, "Interpolated output is not ordinary original-source evidence")
        // An unresolved host producer/journal remains blocked even when ordinary-looking pixels arrive.
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 9, features: ordinaryFeatures, display: 1,
            virtualDisplayActive: false, virtualDisplayPhase: .blocked,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            lease: ordinary, tagGeometry: 9))
        XCTAssertTrue(model.workspaceBetaExitPending)
        XCTAssertFalse(model.canControl)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 9, features: ordinaryFeatures, display: 1,
            virtualDisplayActive: false, virtualDisplayPhase: .idle,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)))
        XCTAssertTrue(model.workspaceBetaExitPending, "Host idle still waits for physical original-source proof")
        model.rotationSourcePresented(try source(width: 720, height: 450, lifetime: ordinary.lifetime,
            lease: ordinary, tagGeometry: 9))
        XCTAssertFalse(model.workspaceBetaExitPending)
        XCTAssertFalse(model.coordinateInputFenced)
        XCTAssertTrue(model.canControl)
        XCTAssertTrue(model.gesture(.click(count: 1)), "Control can resume under the confirmed normal source authority")
    }

    func testBetaPhoneWorkspaceNeedsExplicitEntryAndHostOfferAndCancelsWithoutInputAuthority() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(),
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()), deviceIdiom: .phone)
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "phone-workspace-explicit-entry")
        model.connection.inputPacketSenderForTesting = { _ in true }
        defer { model.connection.stop() }
        model.geometryEpoch = 7
        XCTAssertTrue(model.connection.requestsPhoneWorkspaceBeta)
        XCTAssertFalse(model.enterBetaWorkspace())
        try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 7,
            features: [SessionFeature.phoneWorkspaceBeta, SessionFeature.virtualDisplay], virtualDisplayPhase: .idle)))
        XCTAssertTrue(model.phoneWorkspaceOffered)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport)
        XCTAssertTrue(model.enterBetaWorkspace())
        model.virtualDisplayViewportChanged(size: CGSize(width: 380, height: 240), scale: 3, maximumFPS: 60,
            generation: model.workspaceMeasurementGeneration)
        let viewport = try XCTUnwrap(model.heartbeatAction().virtualDisplayViewport)
        XCTAssertEqual(viewport.experimentalPhoneWorkspace, true)
        XCTAssertEqual(viewport.iPadWorkspace, false)
        XCTAssertFalse(model.workspaceBetaReady)
        XCTAssertFalse(model.canControl, "Host .active alone does not prove a fitted picture")
        model.exitBetaWorkspace()
        XCTAssertTrue(model.workspaceBetaExitPending)
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewportUnavailable, true)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport)
        XCTAssertFalse(model.canControl, "Cancellation is a cleanup command, not pointer authority")
        model.connection.onAuthenticated?()
        XCTAssertFalse(model.workspaceBetaRequested, "A new session cannot inherit opt-in")
        XCTAssertFalse(model.workspaceBetaExitPending)
    }
    #endif

    func testIPadWorkspaceAdvertisesOnlyMeasuredNegotiatedGeometry() throws {
        let model = PhoneRemoteModel(deviceIdiom: .pad)
        defer { model.connection.stop() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "ipad-workspace")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.geometryEpoch = 7
        model.virtualDisplayViewportChanged(size: CGSize(width: 800, height: 600), scale: 2, maximumFPS: 60,
                                            generation: model.workspaceMeasurementGeneration)
        XCTAssertTrue(model.connection.requestsIPadWorkspace)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport, "An older host receives no workspace fields")
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 7,
            features: [SessionFeature.virtualDisplay])))
        let action = model.heartbeatAction()
        XCTAssertEqual(action.virtualDisplayViewport?.iPadWorkspace, true)
        XCTAssertEqual(action.virtualDisplayViewport?.pixelWidth, 1600)
        XCTAssertEqual(action.virtualDisplayViewport?.pixelHeight, 1200)
        XCTAssertNil(action.virtualDisplayViewportUnavailable)
        XCTAssertEqual(action.virtualDisplayResizeHoldSupported, true)
        model.virtualDisplayViewportChanged(size: .zero, scale: 2, maximumFPS: 60,
                                            generation: model.workspaceMeasurementGeneration)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport)
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewportUnavailable, true)
        XCTAssertNil(model.heartbeatAction().virtualDisplayResizeHoldSupported)
    }

    func testIPhoneRejectsLegacyVirtualDisplayAdvertisementAndSendsNoWorkspaceFields() throws {
        let model = PhoneRemoteModel(deviceIdiom: .phone)
        defer { model.connection.stop() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "phone-ordinary-display")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.geometryEpoch = 7
        model.virtualDisplayViewportChanged(size: CGSize(width: 400, height: 800), scale: 3, maximumFPS: 60,
                                            generation: model.workspaceMeasurementGeneration)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 7,
            features: [SessionFeature.virtualDisplay, SessionFeature.displayScale], virtualDisplayActive: true)))
        XCTAssertFalse(model.connection.requestsIPadWorkspace)
        XCTAssertFalse(model.hostFeatures.contains(SessionFeature.virtualDisplay))
        XCTAssertTrue(model.hostFeatures.contains(SessionFeature.displayScale), "The ordinary Big Text path stays available")
        XCTAssertFalse(model.virtualDisplayActive)
        let action = model.heartbeatAction()
        XCTAssertNil(action.virtualDisplayViewport)
        XCTAssertNil(action.virtualDisplayViewportUnavailable)
        XCTAssertNil(action.virtualDisplayResizeHoldSupported)
    }

    func testWorkspaceFreezesPhysicalAspectBeforeGeometryAndInactivePreflightPackets() throws {
        let model = PhoneRemoteModel(deviceIdiom: .pad)
        defer { model.connection.stop() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "ipad-workspace-packet-order")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.geometryEpoch = 7
        let physical = CGSize(width: 1440, height: 900)
        model.sourceSize = physical
        model.virtualDisplayViewportChanged(size: CGSize(width: 800, height: 400), scale: 2, maximumFPS: 60,
                                            generation: model.workspaceMeasurementGeneration)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 7,
            features: [SessionFeature.virtualDisplay], virtualDisplayActive: false)))
        XCTAssertEqual(model.workspaceLayoutSourceSize, physical)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "geometry", x: 800, y: 400, epoch: 8)))
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 0, epoch: 8)))
        XCTAssertFalse(model.virtualDisplayActive)
        XCTAssertEqual(model.sourceSize, CGSize(width: 800, height: 400))
        XCTAssertEqual(model.workspaceLayoutSourceSize, physical, "Featureless preflight is not a route withdrawal")
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 8,
            features: [SessionFeature.virtualDisplay], virtualDisplayActive: true)))
        XCTAssertTrue(model.virtualDisplayActive)
        XCTAssertEqual(model.workspaceLayoutSourceSize, physical)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 8,
            features: [SessionFeature.displayScale], virtualDisplayActive: false)))
        XCTAssertNil(model.workspaceLayoutSourceSize, "An explicit ordinary route clears the reference")
    }

    private func deliberateEndModel(background: FakeBackgroundExecution? = nil) throws -> (PhoneRemoteModel, () -> [ControlPacket]) {
        let model = PhoneRemoteModel(background: background ?? FakeBackgroundExecution())
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "phone-deliberate-end")
        model.geometryEpoch = 1
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 1,
            features: [SessionFeature.backgroundPause, SessionFeature.deliberateEnd])))
        return (model, { packets })
    }

    func testWorkspaceViewportRequiresCurrentAuthenticatedMeasurementAcrossReconnect() throws {
        let model = PhoneRemoteModel(deviceIdiom: .pad)
        defer { model.connection.stop() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "ipad-workspace-old")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.onAuthenticated?()
        model.geometryEpoch = 7
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 7,
            features: [SessionFeature.virtualDisplay])))
        let oldGeneration = model.workspaceMeasurementGeneration
        model.virtualDisplayViewportChanged(size: CGSize(width: 800, height: 600), scale: 2, maximumFPS: 60,
                                            generation: oldGeneration)
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewport?.width, 800)
        model.connection.onEnded?()
        XCTAssertGreaterThan(model.workspaceMeasurementGeneration, oldGeneration)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport)
        model.prepareConnection(mode: .picture)
        model.connection.startInputFixtureForTesting(session: "ipad-workspace-new")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.onAuthenticated?()
        model.geometryEpoch = 8
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 8,
            features: [SessionFeature.virtualDisplay])))
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport, "Authentication cannot revive the retired layout")
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewportUnavailable, true)
        model.virtualDisplayViewportChanged(size: CGSize(width: 800, height: 600), scale: 2, maximumFPS: 60,
                                            generation: oldGeneration)
        XCTAssertNil(model.heartbeatAction().virtualDisplayViewport, "A queued old layout generation is ignored")
        model.virtualDisplayViewportChanged(size: CGSize(width: 1000, height: 700), scale: 2, maximumFPS: 60,
                                            generation: model.workspaceMeasurementGeneration)
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewport?.width, 1000)
        XCTAssertEqual(model.heartbeatAction().virtualDisplayViewport?.height, 700)
    }

    func testExplicitEndUsesAcknowledgedCloseWhileNonexplicitFailureDoesNot() throws {
        let (ended, endedPackets) = try deliberateEndModel()
        defer { ended.connection.stop() }
        ended.disconnect()
        XCTAssertEqual(endedPackets().filter { $0.action.action == "sessionEnd" }.count, 1)
        XCTAssertFalse(ended.connection.isRunning)
        XCTAssertTrue(ended.connection.connected, "Only the receipt transport waits; local UI is already ended")
        XCTAssertFalse(ended.canControl)
        let (failed, failedPackets) = try deliberateEndModel()
        defer { failed.connection.stop() }
        failed.disconnect(explicitEnd: false)
        XCTAssertFalse(failedPackets().contains { $0.action.action == "sessionEnd" })
        XCTAssertFalse(failed.connection.connected)
    }

    func testBackgroundHoldUsesPauseAndRetainsThePeerForFreshForegroundResume() throws {
        let (model, packets) = try deliberateEndModel()
        defer { model.connection.stop() }
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 1,
            features: [SessionFeature.backgroundPause, SessionFeature.deliberateEnd, SessionFeature.displayScale], display: 1)))
        var display = DisplayDescriptor(id: 1, name: "Built-in", width: 1470, height: 956)
        display.scaleBaselineWidth = 1470; display.scaleCurrentWidth = 1470
        display.scaleSteps = [ScaleStep(width: 1280, height: 832)]
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "displays", epoch: 1,
            displays: [display], display: 1)))
        XCTAssertTrue(model.bigText.autoApplied)
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        XCTAssertTrue(packets().contains { $0.action.action == "pause" })
        XCTAssertFalse(packets().contains { $0.action.action == "sessionEnd" })
        XCTAssertTrue(model.connection.connected)
        XCTAssertFalse(model.bigText.autoApplied)
        model.sceneChanged(.inactive)
        XCTAssertFalse(packets().contains { $0.action.action == "resume" }, "Inactive return cannot resume held video or input")
        model.sceneChanged(.active)
        XCTAssertTrue(packets().contains { $0.action.action == "resume" })
        XCTAssertFalse(model.bigText.autoApplied)
    }

    func testBackgroundWithoutTimeUsesDeliberateCloseInsteadOfUnexpectedLoss() throws {
        let background = FakeBackgroundExecution(); background.granted = false
        let (model, packets) = try deliberateEndModel(background: background)
        defer { model.connection.stop() }
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        XCTAssertTrue(packets().contains { $0.action.action == "sessionEnd" })
        XCTAssertFalse(model.connection.isRunning)
        XCTAssertFalse(packets().contains { $0.action.action == "pause" })
    }

    /// Downstream model + finite proof + injected public-platform operation boundary; no real native producer.
    private func activePiPModel(coordinator: RemoteCoordinator? = nil, preferences: UserDefaults = .standard) throws -> (PhoneRemoteModel, VideoPresentationAdmission, LifecyclePiPPlatform, () -> [ControlPacket]) {
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let platform = LifecyclePiPPlatform()
        let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in platform })
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip, preferences: preferences, coordinator: coordinator)
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "pip-lifecycle")
        if coordinator != nil { model.connection.onAuthenticated?() }
        model.geometryEpoch = 1
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        let proof = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        model.sendViewOnlyEntryForTesting()
        let entry = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == true })
        XCTAssertNotNil(model.viewOnlyStartDeadlineForTesting)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: true, liveViewOnlyRequestID: entry.action.liveViewOnlyRequestID,
            x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertEqual(platform.starts, 1)
        XCTAssertNil(model.viewOnlyStartDeadlineForTesting, "A correlated manual confirmation retires the entry timeout")
        pip.confirmPlatformStartForTesting(platform)
        XCTAssertEqual(model.pipState, .active)
        return (model, proof, platform, { packets })
    }

    /// Exercises production scene/model/PiP teardown with approved isolated trust and a scripted transport.
    /// No real media route is authorized by the finite downstream fixture proof.
    private func trustedActivePiPModel() throws -> (PhoneRemoteModel, PhoneTrustStore, FakeSignalingTransport) {
        let trust = PhoneTrustStore(records: MemoryStore(), legacy: MemoryStore())
        try trust.saveApproved(TestPairing.invitation())
        let transport = FakeSignalingTransport()
        let coordinator = RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust), signaling: transport)
        let defaults = makeTestDefaults("BackgroundPiPRecovery." + UUID().uuidString)
        let (model, _, _, _) = try activePiPModel(coordinator: coordinator, preferences: defaults)
        return (model, trust, transport)
    }

    func testInvoluntaryBackgroundPiPStopReconnectsOnlyAtActiveWithFreshAuthorization() throws {
        let (model, _, transport) = try trustedActivePiPModel()
        defer { model.disconnect() }
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        XCTAssertTrue(model.pipBackgroundForTesting)
        model.livePiP.stop() // Same stop boundary used by AVKit's didStop callback.
        XCTAssertFalse(model.connection.connected)
        XCTAssertFalse(model.connection.isRunning)
        XCTAssertEqual(transport.connects.count, 0, "No background retries after losing the legitimate PiP consumer")
        model.sceneChanged(.inactive)
        XCTAssertEqual(transport.connects.count, 0, "Inactive return must not consume the foreground recovery intent")
        model.sceneChanged(.active)
        XCTAssertEqual(transport.connects.count, 1)
        XCTAssertEqual(model.resumeState, .reconnecting)
        XCTAssertFalse(model.connection.connected, "Reconnect starts the handshake; it cannot reuse the old authorization")
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.viewOnlyConfirmedForTesting)
        XCTAssertNil(model.connection.presentationDeadline())
        model.sceneChanged(.active)
        XCTAssertEqual(transport.connects.count, 1, "The intent is consumed once")
    }

    func testExplicitEndOrChangedSelectedHostInvalidatesBackgroundPiPRecovery() throws {
        for explicitEnd in [true, false] {
            let (model, trust, transport) = try trustedActivePiPModel()
            defer { model.disconnect() }
            model.sceneChanged(.inactive); model.sceneChanged(.background)
            model.livePiP.stop()
            if explicitEnd { model.disconnect() }
            else {
                try trust.saveApproved(TestPairing.invitation(name: "Other Mac"))
                let other = try XCTUnwrap(trust.snapshot().hosts.last)
                try trust.select(hostID: other.id)
            }
            model.sceneChanged(.inactive); model.sceneChanged(.active)
            XCTAssertEqual(transport.connects.count, 0)
            XCTAssertFalse(model.connection.connected)
            XCTAssertFalse(model.canControl)
        }
    }

    func testReportedMacLockOrPermissionBlockInvalidatesBackgroundPiPRecovery() throws {
        for hostState in [HostPresence.locked.rawValue, MacShareBlocker.screenRecordingOff.rawValue] {
            let (model, _, transport) = try trustedActivePiPModel()
            defer { model.disconnect() }
            model.sceneChanged(.inactive); model.sceneChanged(.background)
            model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 0, epoch: 1, hostState: hostState)))
            model.livePiP.stop()
            model.sceneChanged(.active)
            XCTAssertEqual(transport.connects.count, 0)
            XCTAssertFalse(model.canControl)
        }
    }
    /// Auto-PiP: armed only while a live picture session is in front; the OS start (simulated) keeps the session
    /// through `.inactive` and `.background` while the Mac's live-view-only confirmation is pending; a refusal ends it.
    /// Device 1 Oct 18:16 (build .4): swiping Home never started PiP. AVKit only auto-starts playing content, and a
    /// prepared live source reported paused; iOS can also report `.background` before AVKit's start.
    func testArmedPiPReadsAsPlayingAndWaitsBrieflyInTheBackgroundForTheAutomaticStart() throws {
        for startsInGrace in [true, false] {
            let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
            let platform = LifecyclePiPPlatform()
            let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in platform })
            let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip)
            defer { model.disconnect() }
            model.prepareConnection(mode: .picture); model.sceneChanged(.active)
            model.connection.startInputFixtureForTesting(session: "auto-pip-grace")
            model.geometryEpoch = 1
            var packets: [ControlPacket] = []
            model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
            _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
            XCTAssertEqual(model.pipState, .ready)
            XCTAssertFalse(pip.playbackPaused, "an armed live source must read as playing or AVKit never auto-starts it")
            _ = try model.files.engine.request().get()
            XCTAssertTrue(model.files.isBusy)
            model.sceneChanged(.inactive); model.sceneChanged(.background)
            XCTAssertFalse(model.files.isBusy, "file I/O stops at the background even while the PiP grace waits")
            XCTAssertFalse(model.contentConcealed, "the prepared PiP gets a grace before the background teardown")
            XCTAssertTrue(model.privacyShield, "the app-switcher snapshot stays shielded during the grace")
            XCTAssertEqual(model.pipState, .ready)
            if startsInGrace {
                pip.automaticStartForTesting(platform)
                pip.confirmPlatformStartForTesting(platform)
                XCTAssertTrue(model.pipBackgroundForTesting); XCTAssertEqual(model.pipState, .active)
                XCTAssertTrue(packets.contains { $0.action.action == "viewOnly" && $0.action.liveViewOnly == true })
            }
            let end = Date().addingTimeInterval(PhoneRemoteModel.autoPiPBackgroundGraceSeconds + 0.5)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if startsInGrace {
                XCTAssertEqual(model.pipState, .active, "a PiP that started holds the session"); XCTAssertTrue(model.connection.connected)
            } else {
                XCTAssertTrue(model.contentConcealed, "no start: the normal background path follows")
                XCTAssertNotEqual(model.pipState, .ready, "and the prepared PiP is retired")
            }
        }
        let pip = LivePiPController(mediaSession: PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {})),
                                    supported: { true }, platformFactory: { _, _ in LifecyclePiPPlatform() })
        XCTAssertTrue(pip.playbackPaused, "nothing prepared reads as paused")
    }
    /// Review P2: dictation after arming leaves the audio category at .record; leaving the app re-prepares .playback.
    func testLeavingWhileArmedRestoresThePlaybackCategoryAfterDictation() throws {
        var configured: [PhoneMediaSession.Configuration] = []
        let registry = PhoneMediaSession(backend: .init(configure: { configured.append($0) }, activate: {}, deactivate: {}))
        let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in LifecyclePiPPlatform() })
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip)
        defer { model.disconnect() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "auto-pip-category")
        model.geometryEpoch = 1
        _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        XCTAssertTrue(pip.automaticStartAllowed)
        XCTAssertEqual(configured.last, .playback, "arming prepares the playback category")
        let dictation = UUID()
        XCTAssertTrue(registry.acquire(dictation, kind: .recording, onRetired: {}))
        XCTAssertEqual(configured.last, .recording)
        registry.release(dictation)
        model.sceneChanged(.inactive)
        XCTAssertEqual(configured.last, .playback, "leaving while armed restores it before the OS decides")
    }
    func testLeavingALivePictureSessionStartsPiPAutomaticallyAndTheMacMustConfirmViewOnly() throws {
        // (refuse, the Mac answers before AVKit finishes the start: the usual order on a LAN)
        for (refuse, confirmFirst) in [(false, false), (true, false), (false, true)] {
            let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
            let platform = LifecyclePiPPlatform()
            let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in platform })
            let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip)
            defer { model.disconnect() }
            model.prepareConnection(mode: .picture); model.sceneChanged(.active)
            model.connection.startInputFixtureForTesting(session: "auto-pip")
            model.geometryEpoch = 1
            var packets: [ControlPacket] = []
            model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
            _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
            XCTAssertTrue(pip.automaticStartAllowed, "armed while live in the foreground")
            XCTAssertTrue(model.showsInlinePiPSource)
            model.sceneChanged(.inactive)
            XCTAssertEqual(model.pipState, .ready, "the prepared PiP survives the shield so the OS can still start it")
            pip.automaticStartForTesting(platform)
            XCTAssertEqual(platform.starts, 0, "the OS starts it; the app never calls start in the background")
            let entry = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == true })
            XCTAssertTrue(pip.automaticStartUnconfirmed, "only the last inline frame shows until the Mac confirms")
            let reply = RemoteAction(action: "capture", liveViewOnly: !refuse, liveViewOnlyRequestID: entry.action.liveViewOnlyRequestID,
                                     x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])
            if confirmFirst {
                model.connection.onControl?(try JSONEncoder().encode(reply))
                XCTAssertFalse(pip.automaticStartUnconfirmed)
                model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 0.3)
                XCTAssertEqual(model.pipState, .starting, "a confirmed start still finishing in AVKit is kept")
                model.sceneChanged(.background)
                pip.confirmPlatformStartForTesting(platform)
                XCTAssertEqual(model.pipState, .active); XCTAssertTrue(model.connection.connected)
                XCTAssertTrue(model.pipBackgroundForTesting)
                continue
            }
            pip.confirmPlatformStartForTesting(platform)
            XCTAssertEqual(model.pipState, .active)
            model.sceneChanged(.background)
            XCTAssertTrue(model.pipBackgroundForTesting); XCTAssertTrue(model.connection.connected)
            model.connection.onControl?(try JSONEncoder().encode(reply))
            if refuse {
                XCTAssertFalse(model.connection.connected, "a Mac that refuses live view only ends the background PiP")
            } else {
                XCTAssertTrue(model.viewOnlyConfirmedForTesting); XCTAssertEqual(model.pipState, .active)
                XCTAssertTrue(model.connection.connected)
            }
        }
        let suite = "auto-pip-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PhoneRemoteModel.autoPiPDisabledKey)
        let pip = LivePiPController(mediaSession: PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {})),
                                    supported: { true }, platformFactory: { _, _ in LifecyclePiPPlatform() })
        let off = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip, preferences: defaults)
        defer { off.disconnect() }
        off.prepareConnection(mode: .picture); off.sceneChanged(.active)
        off.connection.startInputFixtureForTesting(session: "auto-pip-off"); off.geometryEpoch = 1
        _ = off.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        XCTAssertFalse(pip.automaticStartAllowed, "the internal kill switch disarms it")
        XCTAssertFalse(off.showsInlinePiPSource)
    }
    /// Crash 1 Oct 15:33 (build .3): tapping the PiP window to return ran AVKit's restore completion after the
    /// foreground return had already stopped the PiP and released its controller, so AVKit read freed memory.
    func testPiPRestoreKeepsThePlatformControllerAliveUntilTheCompletionReturns() throws {
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        weak var latest: LifecyclePiPPlatform?
        let pip = LivePiPController(mediaSession: registry, supported: { true },
                                    platformFactory: { _, _ in let made = LifecyclePiPPlatform(); latest = made; return made })
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), livePiP: pip)
        defer { model.disconnect() }
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "pip-restore-lifetime")
        model.geometryEpoch = 1
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        _ = model.admitPiPProofForTesting(validUntil: ProcessInfo.processInfo.systemUptime + 20)
        model.sendViewOnlyEntryForTesting()
        let entry = try XCTUnwrap(packets.last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == true })
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: true,
            liveViewOnlyRequestID: entry.action.liveViewOnlyRequestID, x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        weak var started: LifecyclePiPPlatform?
        var aliveAtCompletion: Bool?, restored: Bool?
        do {
            let platform = try XCTUnwrap(latest)
            started = platform
            pip.confirmPlatformStartForTesting(platform)
            XCTAssertEqual(model.pipState, .active)
            model.sceneChanged(.inactive); model.sceneChanged(.background)
            XCTAssertTrue(model.pipBackgroundForTesting)
            pip.restoreUserInterfaceForTesting(on: platform) { aliveAtCompletion = started != nil; restored = $0 }
        }
        XCTAssertNil(aliveAtCompletion, "the restore waits for the foreground")
        model.sceneChanged(.active) // Returning stops the PiP (releasing its controller), then completes the restore.
        XCTAssertEqual(restored, true)
        XCTAssertFalse(pip.controller === started, "the foreground return did stop that PiP before completing")
        XCTAssertEqual(aliveAtCompletion, true, "AVKit's completion must never run after its controller was freed")
    }
    func testActivePiPSurvivesInactiveHeartbeatThenBackgroundWithoutExitOrPause() throws {
        let (model, _, _, packets) = try activePiPModel()
        defer { model.disconnect() }
        let lifetime = try XCTUnwrap(model.pipAdmission).lifetime
        model.sceneChanged(.inactive)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 0.3)
        XCTAssertEqual(model.pipState, .active); XCTAssertTrue(model.connection.connected)
        XCTAssertTrue(model.pipAdmission?.lifetime === lifetime)
        XCTAssertFalse(model.awaitingViewOnlyExitForTesting)
        model.sceneChanged(.background)
        XCTAssertTrue(model.pipBackgroundForTesting); XCTAssertTrue(model.connection.connected)
        XCTAssertEqual(model.pipState, .active)
        XCTAssertFalse(packets().contains { $0.action.action == "pause" || $0.action.liveViewOnly == false })
    }
    func testBackgroundPiPPauseHoldsTheSessionAndResumeContinues() throws {
        let (model, _, platform, packets) = try activePiPModel()
        defer { model.disconnect() }
        let lifetime = try XCTUnwrap(model.pipAdmission).lifetime
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        XCTAssertTrue(model.pipBackgroundForTesting)
        model.livePiP.setPlayingForTesting(false, on: platform)
        XCTAssertEqual(model.pipState, .paused)
        XCTAssertTrue(model.connection.connected, "The PiP pause button holds the session")
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 0.3)
        XCTAssertEqual(model.pipState, .paused, "The heartbeat keeps a paused background PiP admitted")
        XCTAssertTrue(model.pipAdmission?.lifetime === lifetime)
        XCTAssertTrue(model.connection.connected)
        model.livePiP.setPlayingForTesting(true, on: platform)
        XCTAssertEqual(model.pipState, .active)
        XCTAssertTrue(model.connection.connected); XCTAssertTrue(model.pipBackgroundForTesting)
        XCTAssertFalse(packets().contains { $0.action.action == "pause" || $0.action.liveViewOnly == false })
    }
    func testOpeningTheAppFromAPausedBackgroundPiPKeepsTheSession() throws {
        let (model, _, platform, packets) = try activePiPModel()
        defer { model.disconnect() }
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        model.livePiP.setPlayingForTesting(false, on: platform)
        model.sceneChanged(.inactive)
        XCTAssertTrue(model.connection.connected, "The app-switcher return passes .inactive with the privacy shield up")
        XCTAssertEqual(model.pipState, .paused)
        model.sceneChanged(.active)
        XCTAssertTrue(model.connection.connected)
        XCTAssertFalse(model.pipBackgroundForTesting)
        XCTAssertTrue(packets().contains { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false },
                      "Foreground return asks the Mac to leave view-only, as it does for a playing PiP")
    }
    func testControlCenterReturnKeepsSamePiPConsentAndLifetime() throws {
        let (model, _, _, packets) = try activePiPModel()
        defer { model.disconnect() }
        let lifetime = try XCTUnwrap(model.pipAdmission).lifetime
        model.sceneChanged(.inactive)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 0.3)
        model.sceneChanged(.active)
        XCTAssertEqual(model.pipState, .active)
        XCTAssertTrue(model.pipAdmission?.lifetime === lifetime)
        XCTAssertTrue(model.connection.connected); XCTAssertFalse(model.awaitingViewOnlyExitForTesting)
        XCTAssertFalse(packets().contains { $0.action.liveViewOnly == false })
    }
    func testPiPRestoreWaitsForForegroundAndControlWaitsForExactExitACK() throws {
        let (model, _, _, packets) = try activePiPModel()
        defer { model.disconnect() }
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        var restored: [Bool] = []
        model.livePiP.restoreForeground? { restored.append($0) }
        XCTAssertTrue(restored.isEmpty)
        model.livePiP.stop() // Actual stop ordering before scene active must not disconnect pending restoration.
        XCTAssertTrue(model.connection.connected)
        model.sceneChanged(.active)
        XCTAssertEqual(restored, [true]); XCTAssertTrue(model.connection.connected)
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting); XCTAssertTrue(model.viewOnlyConfirmedForTesting)
        let exit = try XCTUnwrap(packets().last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false })
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: false, liveViewOnlyRequestID: String(repeating: "b", count: 32),
            x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: false, liveViewOnlyRequestID: exit.action.liveViewOnlyRequestID,
            x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertFalse(model.awaitingViewOnlyExitForTesting); XCTAssertFalse(model.viewOnlyConfirmedForTesting)
    }
    func testPendingPiPExitSurvivesRepeatedUnhealthyRetirementAndRejectsDuplicateACK() throws {
        let (model, _, _, packets) = try activePiPModel()
        defer { model.disconnect() }
        model.sceneChanged(.inactive); model.sceneChanged(.background)
        var restored: [Bool] = []
        model.livePiP.restoreForeground? { restored.append($0) }
        model.livePiP.stop()
        model.sceneChanged(.active)
        XCTAssertEqual(restored, [true])
        let exit = try XCTUnwrap(packets().last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false })
        let exitID = try XCTUnwrap(exit.action.liveViewOnlyRequestID)
        // The real foreground path already clears capture readiness. Another unhealthy
        // status must retire pixels without dropping the host cleanup correlation.
        model.captureHealthy = false
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: false,
            liveViewOnlyRequestID: String(repeating: "b", count: 32), x: 0, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting)
        XCTAssertTrue(model.viewOnlyConfirmedForTesting)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(packets().filter { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false }.count, 1,
            "Repeated retirement must not replace the pending exit with another request")
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: false,
            liveViewOnlyRequestID: exitID, x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertFalse(model.awaitingViewOnlyExitForTesting)
        XCTAssertFalse(model.viewOnlyConfirmedForTesting)
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", liveViewOnly: true,
            liveViewOnlyRequestID: exitID, x: 1, epoch: 1, features: [SessionFeature.liveViewOnly])))
        XCTAssertFalse(model.viewOnlyConfirmedForTesting, "A duplicate old ACK cannot re-enter view-only or restart PiP")
        XCTAssertNotEqual(model.pipState, .active)
        XCTAssertTrue(model.connection.connected)
    }
    func testPiPRestoreTimeoutAndEndCannotResurrectRetiredSession() throws {
        for explicitEnd in [true, false] {
            let (model, _, _, _) = try activePiPModel()
            model.sceneChanged(.inactive); model.sceneChanged(.background)
            var restored: [Bool] = []
            model.livePiP.restoreForeground? { restored.append($0) }
            model.livePiP.stop()
            if explicitEnd { model.disconnect() }
            else { model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 3) }
            XCTAssertEqual(restored, [false]); XCTAssertFalse(model.connection.connected)
            model.sceneChanged(.active)
            XCTAssertFalse(model.connection.isRunning); XCTAssertEqual(restored, [false])
        }
    }
    func testPiPRevokedDuringInactiveFailsClosedAndActuallyRequestsHostExit() throws {
        let (model, proof, _, packets) = try activePiPModel()
        defer { model.disconnect() }
        model.sceneChanged(.inactive); proof.lifetime.retire()
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 0.3)
        XCTAssertNotEqual(model.pipState, .active)
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting)
        XCTAssertTrue(packets().contains { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false && $0.action.liveViewOnlyRequestID != nil })
        model.sceneChanged(.active)
        XCTAssertNotEqual(model.pipState, .active, "No automatic OS restart after terminal retirement")
    }

    func testAcceptedLockThenBackgroundAndActiveNeverHoldsResumesOrRetries() throws {
        let background = FakeBackgroundExecution()
        let suite = "lock-background-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resumeStore = SessionResumeStore(defaults: defaults)
        let model = PhoneRemoteModel(background: background, resumeStore: resumeStore)
        model.prepareConnection(mode: .picture); model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "away-lock-background")
        defer { model.connection.stop() }
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        let request = PhoneAwayLockRequest(hostKey: "exact-fixture-host", session: model.connection.presentationSessionID,
            epoch: 7, sentAt: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(model.sendAdmittedLockMacForTesting(request))
        XCTAssertTrue(model.lockMacPendingForTesting)
        XCTAssertEqual(packets.filter { $0.action.action == "lockMac" }.count, 1)
        model.sceneChanged(.inactive)
        XCTAssertEqual(background.begins, 0)
        model.sceneChanged(.background)
        XCTAssertFalse(model.lockMacPendingForTesting)
        XCTAssertFalse(model.connection.connected)
        XCTAssertFalse(model.connection.isRunning)
        XCTAssertEqual(background.begins, 0, "Pending End and Lock cannot request ordinary background time")
        XCTAssertNil(model.backgroundHoldEndsAt)
        XCTAssertNil(resumeStore.load())
        XCTAssertNil(model.viewportResume)
        XCTAssertTrue(model.macNotice?.contains("wasn’t confirmed") == true)
        model.sceneChanged(.active)
        XCTAssertFalse(model.connection.isRunning, "Quick foreground return cannot retry the ended session")
        XCTAssertFalse(packets.contains { ["pause", "resume"].contains($0.action.action) })
        XCTAssertNil(resumeStore.load())
    }

    func testEditableFocusReplyOpensOnlyForNewestFreshClickOnce() {
        var gate = TextFocusProbeGate()
        let first = gate.begin(epoch: 9, at: 10)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let second = gate.begin(epoch: 9, at: 10.1)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.consume(probe: first, editable: true, responseEpoch: 9,
                                    currentEpoch: 9, at: 10.2, allowed: true))
        XCTAssertTrue(gate.consume(probe: second, editable: true, responseEpoch: 9,
                                   currentEpoch: 9, at: 10.3, allowed: true))
        XCTAssertFalse(gate.consume(probe: second, editable: true, responseEpoch: 9,
                                    currentEpoch: 9, at: 10.4, allowed: true), "Reply is one-shot")
    }

    func testEditableFocusReplyRejectsLateWrongEpochNoneditableAndDismissed() {
        var gate = TextFocusProbeGate()
        let expired = gate.begin(epoch: 4, at: 20)
        XCTAssertFalse(gate.consume(probe: expired, editable: true, responseEpoch: 4,
                                    currentEpoch: 4, at: 21.01, allowed: true))
        let staleEpoch = gate.begin(epoch: 4, at: 30)
        XCTAssertFalse(gate.consume(probe: staleEpoch, editable: true, responseEpoch: 4,
                                    currentEpoch: 5, at: 30.1, allowed: true))
        let noneditable = gate.begin(epoch: 5, at: 40)
        XCTAssertFalse(gate.consume(probe: noneditable, editable: false, responseEpoch: 5,
                                    currentEpoch: 5, at: 40.1, allowed: true))
        let inactive = gate.begin(epoch: 5, at: 50)
        XCTAssertFalse(gate.consume(probe: inactive, editable: true, responseEpoch: 5,
                                    currentEpoch: 5, at: 50.1, allowed: false))
        let dismissed = gate.begin(epoch: 5, at: 60)
        gate.invalidate()
        XCTAssertFalse(gate.consume(probe: dismissed, editable: true, responseEpoch: 5,
                                    currentEpoch: 5, at: 60.1, allowed: true),
                       "Manual keyboard dismissal and modal opening invalidate pending focus")
    }

    func testPointerFollowAcceptsValidRoundTripBeyondEightyMillisecondsAndStopsOnLift() {
        let locator = PointerLocator()
        var followed: [CGPoint] = []
        let subscription = locator.followUpdates.sink { followed.append($0) }
        defer { subscription.cancel() }

        locator.moved(at: 10)
        let probe = try! XCTUnwrap(locator.poll(at: 10.05, available: true))
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: probe,
                                     pointerLocation: PointerLocation(x: 900, y: 600)),
                        at: 10.24, sourceSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(followed, [CGPoint(x: 900, y: 600)], "A valid 190 ms reply should still follow")

        locator.moved(at: 11)
        let lateProbe = try! XCTUnwrap(locator.poll(at: 11.01, available: true))
        locator.stopFollowing()
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: lateProbe,
                                     pointerLocation: PointerLocation(x: 950, y: 620)),
                        at: 11.18, sourceSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(followed.count, 1, "A lifted finger must not retarget the viewport")
    }

    func testPointerFollowKeepsZoomedTargetAboveOpenDock() {
        var viewport = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                         canvasSize: CGSize(width: 390, height: 844), mode: .fill,
                                         zoom: 1.6, safeInsets: ViewportInsets(top: 50, bottom: 34))
        let canvas = CGRect(x: 0, y: 100, width: 390, height: 844)
        let dock = CGRect(x: 12, y: 760, width: 366, height: 184)
        let usable = PointerFollowLayout.usableRect(safeRect: viewport.safeRect,
                                                   canvasFrame: canvas, dockFrame: dock)
        XCTAssertEqual(usable.maxY, 648, accuracy: 0.001)
        let point = CGPoint(x: 720, y: 800)
        XCTAssertTrue(viewport.reveal(sourcePoint: point, in: usable))
        XCTAssertLessThanOrEqual(viewport.viewPoint(fromSource: point).y, usable.maxY - 32 + 0.001)
    }

    func testInactiveInterruptionsShieldThePictureButKeepTheSession() {
        let model = PhoneRemoteModel()
        model.sceneChanged(.active)
        let statusBefore = model.connection.status
        let inputRevisionBefore = model.inputRevision

        model.sceneChanged(.inactive)
        XCTAssertTrue(model.privacyShield, "Control Center or a call banner hides the picture")
        XCTAssertGreaterThan(model.inputRevision, inputRevisionBefore, "Interrupted touches and held input must be cancelled")
        XCTAssertFalse(model.contentConcealed, "An inactive scene must not end the session")
        XCTAssertEqual(model.connection.status, statusBefore, "An inactive scene must not disconnect")

        model.sceneChanged(.active)
        XCTAssertFalse(model.privacyShield, "Returning from Control Center restores the picture")
        XCTAssertFalse(model.contentConcealed)
        XCTAssertEqual(model.connection.status, statusBefore)
    }

    func testInactiveConnectedWindowDoesNotStartAConnectionExpiryTimer() throws {
        let background = FakeBackgroundExecution()
        let model = PhoneRemoteModel(background: background)
        defer { model.disconnect() }
        model.prepareConnection(mode: .picture)
        model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "duo-focus")
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.geometryEpoch = 1
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 1,
            features: [SessionFeature.backgroundPause])))
        let revision = model.inputRevision
        model.sceneChanged(.inactive)
        XCTAssertEqual(background.begins, 0, "Split View focus loss must not expire a foreground session")
        XCTAssertTrue(model.connection.connected)
        XCTAssertTrue(model.privacyShield)
        XCTAssertGreaterThan(model.inputRevision, revision)
        model.sceneChanged(.active)
        XCTAssertTrue(model.connection.connected)
        XCTAssertFalse(model.privacyShield)
        model.sceneChanged(.background)
        XCTAssertTrue(model.contentConcealed, "Real backgrounding still conceals and uses the existing hold policy")
        XCTAssertEqual(background.begins, 1)
    }

    func testBackgroundWithoutASessionConcealsTheSnapshotAndReturnsHome() {
        let background = FakeBackgroundExecution()
        let model = PhoneRemoteModel(background: background)
        let statusBefore = model.connection.status
        model.sceneChanged(.active)
        model.sceneChanged(.inactive)
        XCTAssertEqual(background.begins, 0, "No session means no background time is requested")
        model.sceneChanged(.background)
        XCTAssertTrue(model.contentConcealed, "The app switcher snapshot never shows the previous screen")
        XCTAssertEqual(model.resumeState, .backgrounded)
        XCTAssertFalse(model.privacyShield)
        XCTAssertEqual(model.connection.status, statusBefore, "There was nothing to disconnect")
        XCTAssertFalse(background.isActive)

        model.sceneChanged(.inactive)
        model.sceneChanged(.active)
        XCTAssertFalse(model.contentConcealed, "Returning with nothing to resume goes straight home")
        XCTAssertEqual(model.resumeState, .none)
        XCTAssertFalse(model.connection.isRunning, "Nothing reconnects on its own without a prior session")
    }

    func testBackgroundCancelsHeldInputAndPendingClipboardWork() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.sceneChanged(.active)
        model.modifiers = ["command"]
        let revision = model.inputRevision
        model.sceneChanged(.background)
        XCTAssertTrue(model.modifiers.isEmpty, "Held modifiers are released on backgrounding")
        XCTAssertGreaterThan(model.inputRevision, revision)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.clipboard.activity, .idle)
    }

    func testConcealedRecoveryCanAlwaysReturnHome() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.sceneChanged(.active)
        model.sceneChanged(.background)
        model.dismissConcealment()
        XCTAssertFalse(model.contentConcealed)
        XCTAssertEqual(model.resumeState, .none)
    }

    func testMacReportedDeparturesAreExplainedWithoutGuessing() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let time = date.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(PhoneRemoteModel.notice(for: .sleeping, at: date), "Your Mac went to sleep at \(time). Wake it to reconnect.")
        XCTAssertTrue(PhoneRemoteModel.notice(for: .locked, at: date).contains("can’t unlock it"))
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertNil(model.macNotice, "Nothing is claimed without a report from the Mac")
        XCTAssertFalse(model.canWakeDisplay)
    }

    func testClipboardActionsExplainWhyTheyAreUnavailable() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.clipboardSupported)
        XCTAssertFalse(model.clipboardAvailable)
        model.pasteToMac(["secret"])
        XCTAssertEqual(model.clipboard.notice?.message, "Connect to your Mac to use the clipboard.")
        model.copySelectionFromMac()
        XCTAssertEqual(model.clipboard.activity, .idle)
        XCTAssertFalse(model.commandShortcut("c"), "⌘C needs live control")
    }

    func testLaunchTransitionsBeforeFirstActivationDoNothing() {
        let model = PhoneRemoteModel()
        model.sceneChanged(.inactive)
        XCTAssertFalse(model.privacyShield)
        model.sceneChanged(.background)
        XCTAssertFalse(model.contentConcealed)
    }
}

final class IPadWorkspaceGeometryTests: XCTestCase {
    private let picture = CGRect(x: 40, y: 20, width: 1024, height: 768)
    private let safe = CGRect(x: 50, y: 30, width: 1004, height: 748)
    private let top = CGRect(x: 250, y: 35, width: 300, height: 45)

    func testUsablePictureExcludesSafeAreasChromeAndSoftwareKeyboard() throws {
        let dock = CGRect(x: 200, y: 730, width: 700, height: 38)
        let normal = try XCTUnwrap(IPadWorkspaceGeometry.usableRect(picture: picture, safe: safe,
            topChrome: top, bottomChrome: dock, keyboardDock: .zero, keyboardOpen: false, scale: 2))
        XCTAssertEqual(normal, CGRect(x: 50, y: 80, width: 1004, height: 650))
        let keyboard = CGRect(x: 50, y: 480, width: 1004, height: 60)
        let typing = try XCTUnwrap(IPadWorkspaceGeometry.usableRect(picture: picture, safe: safe,
            topChrome: top, bottomChrome: .zero, keyboardDock: keyboard, keyboardOpen: true, scale: 2))
        XCTAssertEqual(typing, CGRect(x: 50, y: 80, width: 1004, height: 400))
        let closed = IPadWorkspaceGeometry.usableRect(picture: picture, safe: safe,
            topChrome: top, bottomChrome: dock, keyboardDock: keyboard, keyboardOpen: false, scale: 2)
        XCTAssertEqual(closed, normal, "Dismissal ignores the last keyboard frame and restores the usable extent")
    }

    func testStackedPictureDoesNotShrinkForAKeyboardEntirelyInTheTrackpad() throws {
        let stacked = CGRect(x: 40, y: 20, width: 1024, height: 500)
        let keyboard = CGRect(x: 40, y: 600, width: 1024, height: 60)
        let shown = try XCTUnwrap(IPadWorkspaceGeometry.usableRect(picture: stacked, safe: safe, topChrome: top,
            bottomChrome: .zero, keyboardDock: keyboard, keyboardOpen: true, scale: 2))
        let hidden = IPadWorkspaceGeometry.usableRect(picture: stacked, safe: safe, topChrome: top,
            bottomChrome: .zero, keyboardDock: keyboard, keyboardOpen: false, scale: 2)
        XCTAssertEqual(shown, hidden)
        XCTAssertEqual(shown.size, CGSize(width: 1004, height: 440))
    }

    func testHardwareDraftHoldsTheNegotiatedExtentButSoftwareKeyboardAndRotationUpdateIt() {
        let normal = CGRect(x: 50, y: 80, width: 1004, height: 650)
        let localDraft = CGRect(x: 50, y: 60, width: 1004, height: 700)
        let software = CGRect(x: 50, y: 80, width: 1004, height: 400)
        var geometry = IPadWorkspaceGeometry.DraftGeometry()
        XCTAssertEqual(geometry.update(picture: picture, safe: safe, scale: 2, measured: normal,
                                       hardwareKeyboard: true, keyboardOpen: false), normal)
        XCTAssertEqual(geometry.update(picture: picture, safe: safe, scale: 2, measured: localDraft,
                                       hardwareKeyboard: true, keyboardOpen: true), normal)
        XCTAssertEqual(geometry.update(picture: picture, safe: safe, scale: 2, measured: software,
                                       hardwareKeyboard: false, keyboardOpen: true), software)
        XCTAssertEqual(geometry.update(picture: picture, safe: safe, scale: 2, measured: normal,
                                       hardwareKeyboard: true, keyboardOpen: true), normal,
                       "Attaching hardware first replaces the software-keyboard-reduced workspace")
        XCTAssertEqual(geometry.update(picture: picture, safe: safe, scale: 2, measured: localDraft,
                                       hardwareKeyboard: true, keyboardOpen: true), normal,
                       "Only subsequent local hardware-draft chrome keeps the negotiated extent")
        let rotatedPicture = CGRect(x: 0, y: 0, width: 768, height: 1024)
        let rotated = CGRect(x: 0, y: 60, width: 768, height: 950)
        XCTAssertEqual(geometry.update(picture: rotatedPicture, safe: rotatedPicture, scale: 2,
                                       measured: rotated, hardwareKeyboard: true, keyboardOpen: true), rotated)
    }

    func testNegotiatedWorkspaceFitsInsideUsablePictureAndKeepsInputCornersAligned() throws {
        let usable = try XCTUnwrap(IPadWorkspaceGeometry.usableRect(picture: picture, safe: safe, topChrome: top,
            bottomChrome: .zero, keyboardDock: CGRect(x: 50, y: 480, width: 1004, height: 60),
            keyboardOpen: true, scale: 2))
        let local = usable.offsetBy(dx: -picture.minX, dy: -picture.minY)
        let source = CGSize(width: usable.width * 2, height: usable.height * 2)
        let viewport = ViewportTransform(sourceSize: source, canvasSize: picture.size, mode: .fit,
            safeInsets: ViewportInsets(top: local.minY, left: local.minX,
                bottom: picture.height - local.maxY, right: picture.width - local.maxX))
        XCTAssertEqual(viewport.contentRect, local)
        XCTAssertEqual(viewport.sourcePoint(fromView: local.origin), .zero)
        XCTAssertEqual(viewport.sourcePoint(fromView: CGPoint(x: local.maxX, y: local.maxY)),
                       CGPoint(x: source.width, y: source.height))
    }

    func testFractionalUsableEdgesAlignInwardToAnExactEvenRaster() throws {
        let canvas = CGRect(x: 5.25, y: 12.5, width: 834, height: 1210)
        let safe = canvas.insetBy(dx: 0.3, dy: 10.1)
        for scale in [CGFloat(2), 3] {
            let usable = try XCTUnwrap(IPadWorkspaceGeometry.usableRect(picture: canvas, safe: safe,
                topChrome: .zero, bottomChrome: .zero, keyboardDock: .zero, keyboardOpen: false, scale: scale))
            XCTAssertGreaterThanOrEqual(usable.minX, safe.minX)
            XCTAssertGreaterThanOrEqual(usable.minY, safe.minY)
            XCTAssertLessThanOrEqual(usable.maxX, safe.maxX)
            XCTAssertLessThanOrEqual(usable.maxY, safe.maxY)
            XCTAssertLessThan(safe.width - usable.width, 4 / scale)
            XCTAssertLessThan(safe.height - usable.height, 4 / scale)
            let request = VirtualDisplayViewport(width: Double(usable.width), height: Double(usable.height),
                scale: Double(scale), maximumFPS: 60, iPadWorkspace: true)
            XCTAssertNoThrow(try request.validate())
            XCTAssertEqual(request.pixelWidth % 2, 0)
            XCTAssertEqual(request.pixelHeight % 2, 0)
        }
        XCTAssertNil(IPadWorkspaceGeometry.usableRect(picture: canvas, safe: .zero,
            topChrome: .zero, bottomChrome: .zero, keyboardDock: .zero, keyboardOpen: false, scale: 2))
    }

    func testVirtualAspectNeverFeedsBackIntoTheStackedPictureHeight() {
        let window = CGSize(width: 834, height: 1210)
        let physical = CGSize(width: 1440, height: 900)
        let expected = SessionWindowLayout.pictureSize(window: window, source: physical, stacked: true)
        for workspace in [CGSize(width: 824, height: 450), CGSize(width: 824, height: 300)] {
            let source = IPadWorkspaceGeometry.layoutSource(current: workspace, reference: physical, active: true)
            XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: window, source: source, wasStacked: true))
            XCTAssertEqual(SessionWindowLayout.pictureSize(window: window, source: source, stacked: true), expected)
        }
        XCTAssertEqual(IPadWorkspaceGeometry.layoutSource(current: physical, reference: CGSize(width: 800, height: 600),
                                                         active: false), physical)
    }

    func testAttachedIPadKeyboardKeepsAutomaticEditableFocusOnTheRemoteCanvas() {
        XCTAssertFalse(IPadWorkspaceGeometry.mayOpenAutomaticDraft(isPad: true, hardwareKeyboard: true))
        XCTAssertTrue(IPadWorkspaceGeometry.mayOpenAutomaticDraft(isPad: true, hardwareKeyboard: false))
        XCTAssertTrue(IPadWorkspaceGeometry.mayOpenAutomaticDraft(isPad: false, hardwareKeyboard: true),
                      "The iPhone's existing automatic draft behavior is unchanged")
    }
}

final class ViewportPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ViewportPreferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsToFillAndRemembersTheLastChoice() {
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
        ViewportPreference.store(.fit, in: defaults)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fit)
        ViewportPreference.store(.fit.toggled, in: defaults)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
    }

    func testUnknownStoredValueFallsBackToFill() {
        defaults.set("stretch", forKey: ViewportPreference.key)
        XCTAssertEqual(ViewportPreference.stored(in: defaults), .fill)
    }
}

@MainActor
final class LocalOnlyPreferenceTests: XCTestCase {
    private let suite = "LocalOnlyPreferenceTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testLocalNetworkOnlySurvivesRelaunch() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults)
        XCTAssertFalse(model.connection.localOnly)
        model.setLocalOnly(true)
        XCTAssertTrue(model.connection.localOnly)
        XCTAssertTrue(PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults).connection.localOnly)
        model.setLocalOnly(false)
        XCTAssertFalse(PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults).connection.localOnly)
    }
}
