import XCTest
import SwiftUI
import Combine
import AVKit
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
