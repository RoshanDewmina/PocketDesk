import XCTest
import AVKit
@testable import PocketDeskRemote

@MainActor
final class PhoneMediaSessionIntegrationTests: XCTestCase {
    private func proof() -> VideoPresentationAdmission {
        VideoPresentationAdmission(identity: .init(hostRecordID: "host", ownerPairID: "owner", sessionID: UUID(),
            trackID: UUID(), contentEpoch: 1, geometryEpoch: 1), validUntil: ProcessInfo.processInfo.systemUptime + 20)
    }
    func testActualMacMuteDoesNotDeactivatePreparedPiPAndTerminalStopReleasesLastOwner() {
        var releases = 0, starts = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mac = PhoneSystemAudioPlayback(session: registry)
        let pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in true }, startPlatform: { _ in starts += 1 })
        XCTAssertTrue(mac.begin())
        pip.updateAdmission(proof())
        XCTAssertTrue(pip.startFromUserAction(foreground: true)); XCTAssertEqual(starts, 1)
        mac.end(); mac.end(); XCTAssertEqual(releases, 0)
        pip.stop(); XCTAssertEqual(releases, 1)
        pip.stop(); XCTAssertEqual(releases, 1)
    }
    func testActualPiPPreparesCategoryBeforePossibleAndReleasesRefusedStart() {
        var configured = false, releases = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in configured = true }, activate: {}, deactivate: { releases += 1 }))
        let pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in
            XCTAssertTrue(configured); return false
        }, startPlatform: { _ in XCTFail("No platform start when impossible") })
        pip.updateAdmission(proof())
        XCTAssertFalse(pip.startFromUserAction(foreground: true)); XCTAssertEqual(releases, 1)
        XCTAssertFalse(pip.startFromUserAction(foreground: false)); XCTAssertEqual(releases, 1)
    }
    func testActualControllersRetireWithoutAutomaticRestart() {
        var muted = 0, starts = 0, releases = 0
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mac = PhoneSystemAudioPlayback(session: registry); mac.onMustMute = { [weak mac] in muted += 1; mac?.end() }
        let pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in true }, startPlatform: { _ in starts += 1 })
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
        var started: [AVPictureInPictureController] = []
        let replacement = proof()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in
            if replace { replace = false; pip.updateAdmission(replacement) }
        }, activate: {}, deactivate: { releases += 1 }))
        pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in true }, startPlatform: { started.append($0) })
        defer { pip.stop(); pip = nil }
        pip.updateAdmission(proof())
        let old = try XCTUnwrap(pip.controller)
        XCTAssertFalse(pip.startFromUserAction(foreground: true))
        XCTAssertTrue(started.isEmpty); XCTAssertEqual(releases, 1)
        XCTAssertFalse(pip.controller === old)
        XCTAssertTrue(pip.startFromUserAction(foreground: true))
        XCTAssertEqual(started.count, 1); XCTAssertFalse(started[0] === old)
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
            pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in
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
        var started: [AVPictureInPictureController] = []
        let replacement = proof()
        let registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        pip = LivePiPController(mediaSession: registry, supported: { true }, possible: { _ in
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
        XCTAssertEqual(started.count, 1); XCTAssertFalse(started[0] === old)
        XCTAssertTrue(started[0] === pip.controller)
        XCTAssertEqual(pip.policy.state, .starting)
        XCTAssertEqual(releases, 1, "Refused old start must not deactivate the fresh run")
        pip.stop(); XCTAssertEqual(releases, 2)
    }

}
