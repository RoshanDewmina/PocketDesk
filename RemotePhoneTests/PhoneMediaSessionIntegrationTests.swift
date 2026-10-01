import XCTest
import AVKit
@testable import PocketDeskRemote

/// External platform operations are injected; no fixture manufactures or starts a native AVKit controller.
private final class FixturePiPPlatformController: LivePiPPlatformController {
    var nativeController: AVPictureInPictureController? { nil }
    var possible: () -> Bool = { true }
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var starts = 0, stops = 0
    var isPossible: Bool { possible() }
    func start() { starts += 1; onStart() }
    func stop() { stops += 1; onStop() }
    func invalidatePlaybackState() {}
    func detachDelegate() {}
}

@MainActor
final class PhoneMediaSessionIntegrationTests: XCTestCase {
    private func fixtureController(mediaSession: PhoneMediaSession,
        possible: @escaping (any LivePiPPlatformController) -> Bool = { _ in true },
        startPlatform: @escaping (any LivePiPPlatformController) -> Void = { _ in }) -> LivePiPController {
        LivePiPController(mediaSession: mediaSession, supported: { true }, platformFactory: { _, _ in
            let platform = FixturePiPPlatformController()
            platform.possible = { [weak platform] in guard let platform else { return false }; return possible(platform) }
            platform.onStart = { [weak platform] in if let platform { startPlatform(platform) } }
            return platform
        })
    }
    private func proof() -> VideoPresentationAdmission {
        VideoPresentationAdmission(identity: .init(hostRecordID: "host", ownerPairID: "owner", sessionID: UUID(),
            trackID: UUID(), contentEpoch: 1, geometryEpoch: 1), validUntil: ProcessInfo.processInfo.systemUptime + 20)
    }
    func testInjectedControllersMacMuteDoesNotDeactivatePreparedPiPAndTerminalStopReleasesLastOwner() {
        var releases = 0, starts = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mac = PhoneSystemAudioPlayback(session: registry)
        let pip = fixtureController(mediaSession: registry, possible: { _ in true }, startPlatform: { _ in starts += 1 })
        XCTAssertTrue(mac.begin())
        let admitted = proof(); XCTAssertTrue(admitted.permits(at: ProcessInfo.processInfo.systemUptime))
        pip.updateAdmission(admitted)
        XCTAssertTrue(pip.startFromUserAction(foreground: true)); XCTAssertEqual(starts, 1)
        mac.end(); mac.end(); XCTAssertEqual(releases, 0)
        pip.stop(); XCTAssertEqual(releases, 1)
        pip.stop(); XCTAssertEqual(releases, 1)
    }
    func testInjectedPiPPreparesCategoryBeforePossibleAndReleasesRefusedStart() {
        var configured = false, releases = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in configured = true }, activate: {}, deactivate: { releases += 1 }))
        let pip = fixtureController(mediaSession: registry, possible: { _ in
            XCTAssertTrue(configured); return false
        }, startPlatform: { _ in XCTFail("No platform start when impossible") })
        pip.updateAdmission(proof())
        XCTAssertFalse(pip.startFromUserAction(foreground: true)); XCTAssertEqual(releases, 1)
        XCTAssertFalse(pip.startFromUserAction(foreground: false)); XCTAssertEqual(releases, 1)
    }
    func testInjectedControllersRetireWithoutAutomaticRestart() {
        var muted = 0, starts = 0, releases = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mac = PhoneSystemAudioPlayback(session: registry); mac.onMustMute = { [weak mac] in muted += 1; mac?.end() }
        let pip = fixtureController(mediaSession: registry, possible: { _ in true }, startPlatform: { _ in starts += 1 })
        XCTAssertTrue(mac.begin()); pip.updateAdmission(proof())
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        registry.retireAll()
        XCTAssertEqual(muted, 1); XCTAssertEqual(starts, 1); XCTAssertEqual(releases, 1)
        XCTAssertEqual(pip.policy.state, .ineligible)
        mac.end(); pip.stop(); XCTAssertEqual(releases, 1)
    }
    func testControllerReplacementDuringConfigureRejectsOldStartAndFreshUserStartSucceeds() throws {
        var pip: LivePiPController!
        var replace = true, releases = 0
        var started: [any LivePiPPlatformController] = []
        let replacement = proof()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in
            if replace { replace = false; pip.updateAdmission(replacement) }
        }, activate: {}, deactivate: { releases += 1 }))
        pip = fixtureController(mediaSession: registry, possible: { _ in true }, startPlatform: { started.append($0) })
        defer { pip.stop(); pip = nil }
        pip.updateAdmission(proof())
        let old = try XCTUnwrap(pip.controller)
        XCTAssertFalse(pip.startFromUserAction(foreground: true))
        XCTAssertTrue(started.isEmpty); XCTAssertEqual(releases, 1)
        XCTAssertFalse(pip.controller === old)
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        XCTAssertEqual(started.count, 1); let fresh = try XCTUnwrap(started.first); XCTAssertFalse(fresh === old)
        pip.stop(); XCTAssertEqual(releases, 2)
    }
    func testRetirementDuringConfigureAndPossibleCannotStartOrLeakOwner() {
        for duringConfigure in [true, false] {
            var pip: LivePiPController!
            var retire = true, releases = 0, starts = 0
            let original = proof()
            let registry = PhoneMediaSession(backend: .init(configure: { _ in
                if duringConfigure && retire { retire = false; original.lifetime.retire() }
            }, activate: {}, deactivate: { releases += 1 }))
            pip = fixtureController(mediaSession: registry, possible: { _ in
                if !duringConfigure && retire { retire = false; registry.retireAll() }
                return true
            }, startPlatform: { _ in starts += 1 })
            pip.updateAdmission(original)
            XCTAssertFalse(pip.startFromUserAction(foreground: true))
            XCTAssertEqual(starts, 0); XCTAssertEqual(releases, 1)
            pip.updateAdmission(proof())
            XCTAssertTrue(pip.startFromUserAction(foreground: true)); XCTAssertEqual(starts, 1)
            pip.stop(); XCTAssertEqual(releases, 2)
            pip = nil
        }
    }
    func testReplacementDuringPossibleCannotStartOldOrReleaseNewerRun() throws {
        var pip: LivePiPController!
        var replace = true, releases = 0
        var started: [any LivePiPPlatformController] = []
        let replacement = proof()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        pip = fixtureController(mediaSession: registry, possible: { _ in
            if replace {
                replace = false
                pip.updateAdmission(replacement)
                XCTAssertTrue(pip.startFromUserAction(foreground: true))
            }
            return true
        }, startPlatform: { started.append($0) })
        defer { pip.stop(); pip = nil }
        pip.updateAdmission(proof())
        let old = try XCTUnwrap(pip.controller)
        XCTAssertFalse(pip.startFromUserAction(foreground: true))
        XCTAssertEqual(started.count, 1); let fresh = try XCTUnwrap(started.first); XCTAssertFalse(fresh === old)
        XCTAssertTrue(fresh === pip.controller)
        XCTAssertEqual(pip.policy.state, .starting)
        XCTAssertEqual(releases, 1, "Refused old start must not deactivate the fresh run")
        pip.stop(); XCTAssertEqual(releases, 2)
    }

    func testUnsupportedAndNilFactoryNeverAcquirePlaybackOrLeavePreroll() {
        for supported in [false, true] {
            var configured = 0, activated = 0, factories = 0
            let registry = PhoneMediaSession(backend: .init(configure: { _ in configured += 1 },
                activate: { activated += 1 }, deactivate: { XCTFail("No owner was acquired") }))
            let pip = LivePiPController(mediaSession: registry, supported: { supported }, platformFactory: { _, _ in
                factories += 1; return nil
            })
            let admitted = proof()
            XCTAssertTrue(admitted.permits(at: ProcessInfo.processInfo.systemUptime))
            pip.updateAdmission(admitted)
            XCTAssertEqual(factories, supported ? 1 : 0)
            XCTAssertEqual(pip.policy.state, .ineligible)
            XCTAssertNil(pip.controller); XCTAssertNil(pip.displayLayer)
            XCTAssertFalse(pip.startFromUserAction(foreground: true))
            XCTAssertEqual(configured, 0); XCTAssertEqual(activated, 0)
            pip.stop(); registry.retireAll()
        }
    }

    func testFactoryRetirementCannotInstallControllerOrAcquirePlayback() {
        var factories = 0, configured = 0
        let original = proof(), candidate = FixturePiPPlatformController()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in configured += 1 }, activate: {}, deactivate: {}))
        let pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in
            factories += 1; original.lifetime.retire(); return candidate
        })
        pip.updateAdmission(original)
        XCTAssertEqual(factories, 1); XCTAssertEqual(candidate.stops, 1); XCTAssertEqual(candidate.starts, 0)
        XCTAssertNil(pip.controller); XCTAssertNil(pip.displayLayer); XCTAssertEqual(pip.policy.state, .ineligible)
        XCTAssertFalse(pip.startFromUserAction(foreground: true)); XCTAssertEqual(configured, 0)
    }

    func testFactoryReplacementCannotOverwriteNewControllerOrStopReturnedCurrentReference() throws {
        for returnCurrent in [false, true] {
            var pip: LivePiPController!, replace = true, releases = 0
            let stale = FixturePiPPlatformController(), current = FixturePiPPlatformController(), replacement = proof()
            let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
            pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in
                if replace {
                    replace = false
                    pip.updateAdmission(replacement)
                    return returnCurrent ? current : stale
                }
                return current
            })
            defer { pip.stop(); pip = nil }
            pip.updateAdmission(proof())
            XCTAssertTrue(pip.controller === current)
            XCTAssertEqual(pip.policy.admission?.identity, replacement.identity)
            XCTAssertEqual(current.stops, 0); XCTAssertEqual(stale.stops, returnCurrent ? 0 : 1)
            XCTAssertTrue(pip.startFromUserAction(foreground: true))
            XCTAssertEqual(current.starts, 1); XCTAssertEqual(stale.starts, 0)
            pip.stop(); XCTAssertEqual(releases, 1)
        }
    }

    func testSynchronousPlatformStopCannotReleaseReplacementOwnerOrPreroll() throws {
        var pip: LivePiPController!, factories = 0, releases = 0
        let old = FixturePiPPlatformController(), current = FixturePiPPlatformController(), replacement = proof()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        pip = LivePiPController(mediaSession: registry, supported: { true }, platformFactory: { _, _ in
            factories += 1; return factories == 1 ? old : current
        })
        defer { pip.stop(); pip = nil }
        old.onStop = {
            pip.updateAdmission(replacement)
            XCTAssertTrue(pip.startFromUserAction(foreground: true))
        }
        pip.updateAdmission(proof()); XCTAssertTrue(pip.startFromUserAction(foreground: true))
        pip.stop()
        XCTAssertTrue(pip.controller === current)
        XCTAssertNotNil(pip.displayLayer); XCTAssertEqual(pip.policy.state, .starting)
        XCTAssertEqual(current.starts, 1); XCTAssertEqual(current.stops, 0)
        XCTAssertEqual(releases, 0, "Old stop cleanup must preserve the new playback owner")
        pip.stop(); XCTAssertEqual(releases, 1)
    }

    func testMacPlaybackTemporaryInterruptionPreservesOwnerAndExplicitEndBlocksLateResume() {
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let playback = PhoneSystemAudioPlayback(session: registry)
        var suspended = 0, resumed = 0, muted = 0
        playback.onSuspended = { suspended += 1 }
        playback.onResumed = { resumed += 1; return true }
        playback.onMustMute = { muted += 1 }
        XCTAssertTrue(playback.begin()); XCTAssertTrue(playback.isAdmitted)
        registry.beginInterruption()
        XCTAssertFalse(playback.isAdmitted); XCTAssertTrue(playback.isInterrupted); XCTAssertEqual(suspended, 1)
        registry.endInterruption(shouldResume: true)
        XCTAssertTrue(playback.isAdmitted); XCTAssertEqual(resumed, 1); XCTAssertEqual(muted, 0)
        registry.beginInterruption(); playback.end()
        registry.endInterruption(shouldResume: true)
        XCTAssertFalse(playback.isAdmitted); XCTAssertEqual(resumed, 1)
    }
    func testHeadphonesConnectingKeepMacAudioAndRemovalMutesItWithoutEndingBackgroundPiPOrAutoResuming() throws {
        var muted = 0, releases = 0, resumed = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mac = PhoneSystemAudioPlayback(session: registry)
        mac.onMustMute = { muted += 1 }; mac.onResumed = { resumed += 1; return true }
        let pip = fixtureController(mediaSession: registry)
        XCTAssertTrue(mac.begin()); pip.updateAdmission(proof())
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        let platform = try XCTUnwrap(pip.controller)
        pip.confirmPlatformStartForTesting(platform)
        registry.routeChanged(deviceRemoved: false)
        XCTAssertEqual(pip.policy.state, .active, "AirPods connecting during background PiP keeps PiP")
        XCTAssertEqual(muted, 0); XCTAssertTrue(mac.isAdmitted, "Mac audio moves to the new route")
        registry.routeChanged(deviceRemoved: true)
        XCTAssertEqual(pip.policy.state, .active, "AirPods removed during background PiP keeps PiP")
        XCTAssertEqual((platform as? FixturePiPPlatformController)?.stops, 0)
        XCTAssertEqual(muted, 1); XCTAssertFalse(mac.isAdmitted); XCTAssertEqual(releases, 0)
        registry.beginInterruption(); registry.endInterruption(shouldResume: true)
        XCTAssertEqual(resumed, 0, "a route change does not auto-resume Mac audio")
        XCTAssertFalse(mac.isAdmitted)
        pip.stop(); XCTAssertEqual(releases, 1)
    }

    func testPiPInterruptionCannotResumeExpiredOrReplacementLifetime() throws {
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let pip = fixtureController(mediaSession: registry)
        let admitted = proof(); pip.updateAdmission(admitted)
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        let platform = try XCTUnwrap(pip.controller)
        pip.confirmPlatformStartForTesting(platform)
        XCTAssertEqual(pip.policy.state, .active)
        registry.beginInterruption(); admitted.lifetime.retire()
        registry.endInterruption(shouldResume: true)
        XCTAssertEqual(pip.policy.state, .ineligible)
        let fresh = proof(); pip.updateAdmission(fresh)
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        registry.endInterruption(shouldResume: true)
        XCTAssertEqual(pip.policy.state, .starting)
        pip.stop()
    }

}
