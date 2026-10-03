import XCTest

@MainActor
final class PhoneMediaSessionTests: XCTestCase {
    func testBluetoothMicSwitchReadsOnWhenUnsetAndIsCapturedPerRegistry() {
        for flag in [nil, false, true] as [Bool?] {
            let expected = flag != false // unset reads ON in the .7 test build; explicit NO turns it off
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            if let flag { defaults.set(flag, forKey: "PocketDeskBluetoothMic") }
            var enabled: [Bool] = [], probes = 0
            let session = PhoneMediaSession(backend: .init(configure: { _ in XCTFail("Use the recording configuration seam") },
                activate: {}, deactivate: {}, configureRecording: { enabled.append($0) },
                recordingInputIsBluetooth: { probes += 1; return true }), defaults: defaults)
            defaults.set(!expected, forKey: "PocketDeskBluetoothMic")
            let mic = UUID()
            XCTAssertTrue(session.acquire(mic, kind: .recording, onRetired: {}))
            XCTAssertEqual(enabled, [expected])
            XCTAssertEqual(probes, expected ? 1 : 0)
            XCTAssertEqual(session.recordingUsesBluetoothInput, expected)
            session.release(mic)
            XCTAssertFalse(session.recordingUsesBluetoothInput)
        }
    }

    func testBluetoothInputProbeRunsAfterActivationAndClearsOnTerminalRecordingRetirement() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "PocketDeskBluetoothMic")
        var active = false, probes = 0, retired = 0
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: { active = true },
            deactivate: { active = false }, configureRecording: { XCTAssertTrue($0); XCTAssertFalse(active) },
            recordingInputIsBluetooth: { XCTAssertTrue(active); probes += 1; return true }), defaults: defaults)
        let mic = UUID()
        XCTAssertTrue(session.acquire(mic, kind: .recording, onRetired: {
            retired += 1; XCTAssertFalse(session.recordingUsesBluetoothInput)
        }))
        XCTAssertTrue(session.recordingUsesBluetoothInput)
        XCTAssertFalse(session.acquire(UUID(), kind: .macAudio, onRetired: {}))
        XCTAssertEqual(probes, 1)
        session.routeChanged(deviceRemoved: false)
        XCTAssertEqual(retired, 1); XCTAssertFalse(session.recordingUsesBluetoothInput)
        XCTAssertTrue(session.acquire(UUID(), kind: .recording, onRetired: {}))
        session.beginInterruption()
        XCTAssertFalse(session.recordingUsesBluetoothInput)
        session.endInterruption(shouldResume: true)
        XCTAssertEqual(probes, 2, "Dictation never resumes automatically")
    }

    func testFailedOrRetiredRecordingActivationDoesNotInspectBluetoothRoute() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "PocketDeskBluetoothMic")
        for throwsOnActivate in [false, true] {
            var session: PhoneMediaSession!
            session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {
                if throwsOnActivate { throw Failure.injected }
                session.retireAll()
            }, deactivate: {}, configureRecording: { _ in }, recordingInputIsBluetooth: {
                XCTFail("Retired/failed activation must not inspect a recording route"); return true
            }), defaults: defaults)
            XCTAssertFalse(session.acquire(UUID(), kind: .recording, onRetired: {}))
            XCTAssertFalse(session.recordingUsesBluetoothInput)
        }
    }

    private enum Failure: Error { case injected }
    func testMacMuteCannotDeactivatePiPAndStaleReleaseCannotDropNewRun() {
        var configuration: [PhoneMediaSession.Configuration] = [], activations = 0, releases = 0
        let session = PhoneMediaSession(backend: .init(configure: { configuration.append($0) },
            activate: { activations += 1 }, deactivate: { releases += 1 }))
        let mac = UUID(), pip = UUID(), next = UUID()
        XCTAssertTrue(session.acquire(mac, kind: .macAudio, onRetired: {}))
        XCTAssertTrue(session.acquire(pip, kind: .pictureInPicture, onRetired: {}))
        XCTAssertTrue(session.release(mac)); XCTAssertEqual(releases, 0)
        XCTAssertTrue(session.release(pip)); XCTAssertEqual(releases, 1)
        XCTAssertTrue(session.acquire(next, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.release(pip)); XCTAssertTrue(session.contains(next))
        XCTAssertEqual(releases, 1); XCTAssertEqual(activations, 2)
        XCTAssertEqual(configuration, [.playback, .playback])
        XCTAssertTrue(session.release(next)); XCTAssertEqual(releases, 2)
    }
    func testRecordingAndPlaybackAreMutuallyExclusiveBeforeBackendMutation() {
        var configurations: [PhoneMediaSession.Configuration] = []
        let session = PhoneMediaSession(backend: .init(configure: { configurations.append($0) }, activate: {}, deactivate: {}))
        let pip = UUID(), mic = UUID(), mac = UUID()
        XCTAssertTrue(session.acquire(pip, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.acquire(mic, kind: .recording, onRetired: {}))
        XCTAssertEqual(configurations, [.playback])
        session.release(pip)
        XCTAssertTrue(session.acquire(mic, kind: .recording, onRetired: {}))
        XCTAssertFalse(session.acquire(mac, kind: .macAudio, onRetired: {}))
        XCTAssertFalse(session.acquire(UUID(), kind: .pictureInPicture, onRetired: {}))
        XCTAssertEqual(configurations, [.playback, .recording])
    }
    func testOldVoiceCleanupCannotDeactivateLaterPiP() {
        var releases = 0
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mic = UUID(), pip = UUID()
        XCTAssertTrue(session.acquire(mic, kind: .recording, onRetired: {}))
        session.release(mic)
        XCTAssertTrue(session.acquire(pip, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.release(mic))
        XCTAssertTrue(session.contains(pip)); XCTAssertEqual(releases, 1)
    }
    func testActivationFailureNeverRegistersOwnerAndExplicitRetryIsFresh() {
        var fail = true, deactivated = 0
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: { if fail { throw Failure.injected } },
                                                      deactivate: { deactivated += 1 }))
        let old = UUID(), next = UUID()
        XCTAssertFalse(session.acquire(old, kind: .pictureInPicture, onRetired: { XCTFail("Failed owner is not registered") }))
        XCTAssertFalse(session.contains(old)); XCTAssertTrue(session.lastOperationFailed)
        fail = false
        XCTAssertTrue(session.acquire(next, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.release(old)); XCTAssertEqual(deactivated, 1)
    }
    func testRetirementStopsSnapshotBeforeDeactivationAndDeniesReentrantRestart() {
        var events: [String] = []
        let session = PhoneMediaSession(backend: .init(configure: { _ in events.append("configure") },
            activate: { events.append("activate") }, deactivate: { events.append("deactivate") }))
        let pip = UUID(), mac = UUID()
        XCTAssertTrue(session.acquire(pip, kind: .pictureInPicture, onRetired: {
            events.append("stopPiP")
            XCTAssertFalse(session.contains(pip))
            XCTAssertFalse(session.acquire(UUID(), kind: .pictureInPicture, onRetired: {}))
            XCTAssertFalse(session.release(pip))
        }))
        XCTAssertTrue(session.acquire(mac, kind: .macAudio, onRetired: { events.append("muteMac") }))
        session.retireAll(); session.retireAll()
        XCTAssertEqual(Set(events.dropFirst(2).dropLast()), Set(["stopPiP", "muteMac"]))
        XCTAssertEqual(events.last, "deactivate")
        XCTAssertEqual(events.filter { $0 == "activate" }.count, 1, "Never auto-restart interrupted owners")
        XCTAssertFalse(session.contains(mac)); XCTAssertFalse(session.release(mac))
    }
    func testInterruptionDuringActivationCannotRegisterLateOwnerOrReenterConfiguration() {
        var registry: PhoneMediaSession!
        var configured = 0, deactivated = 0
        registry = PhoneMediaSession(backend: .init(configure: { _ in configured += 1 }, activate: {
            XCTAssertFalse(registry.acquire(UUID(), kind: .recording, onRetired: {}))
            registry.retireAll()
        }, deactivate: { deactivated += 1 }))
        let owner = UUID()
        XCTAssertFalse(registry.acquire(owner, kind: .pictureInPicture, onRetired: { XCTFail("Never admitted") }))
        XCTAssertFalse(registry.contains(owner)); XCTAssertTrue(registry.lastOperationFailed)
        XCTAssertEqual(configured, 1); XCTAssertEqual(deactivated, 1)
    }

    func testLastOwnerDeactivationCannotReenterAcquisitionOrRetirementRestart() {
        var registry: PhoneMediaSession!
        var duringDeactivation = true, releases = 0
        registry = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {
            releases += 1
            if duringDeactivation {
                XCTAssertFalse(registry.acquire(UUID(), kind: .pictureInPicture, onRetired: {}))
                registry.retireAll()
                XCTAssertFalse(registry.acquire(UUID(), kind: .recording, onRetired: {}))
            }
        }))
        let old = UUID(), next = UUID()
        XCTAssertTrue(registry.acquire(old, kind: .pictureInPicture, onRetired: {}))
        XCTAssertTrue(registry.release(old)); XCTAssertEqual(releases, 1)
        duringDeactivation = false
        XCTAssertTrue(registry.acquire(next, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(registry.release(old)); XCTAssertTrue(registry.contains(next))
        XCTAssertEqual(releases, 1)
        registry.release(next); XCTAssertEqual(releases, 2)
    }

    func testDeviceRemovalRetiresMacAudioButKeepsPictureInPictureAndInterruptionStillRetiresAll() {
        var events: [String] = []
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { events.append("deactivate") }))
        let pip = UUID(), mac = UUID()
        XCTAssertTrue(session.acquire(pip, kind: .pictureInPicture, onRetired: { events.append("stopPiP") }))
        XCTAssertTrue(session.acquire(mac, kind: .macAudio, onRetired: {
            events.append("muteMac")
            XCTAssertFalse(session.acquire(UUID(), kind: .macAudio, onRetired: {}), "no restart inside retirement")
        }))
        session.routeChanged(deviceRemoved: false)
        XCTAssertTrue(events.isEmpty, "a newly connected device carries Mac audio and PiP on")
        XCTAssertTrue(session.contains(pip)); XCTAssertTrue(session.contains(mac))
        session.routeChanged(deviceRemoved: true)
        XCTAssertEqual(events, ["muteMac"], "removing AirPods must not stop PiP or deactivate its session")
        XCTAssertTrue(session.contains(pip)); XCTAssertFalse(session.contains(mac))
        session.routeChanged(deviceRemoved: true); XCTAssertEqual(events, ["muteMac"])
        session.retireAll()
        XCTAssertEqual(events, ["muteMac", "stopPiP", "deactivate"])
    }
    func testAnyDeviceChangeEndsDictationAndDeactivatesWhenItWasTheLastOwner() {
        var retired = 0, releases = 0
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let mic = UUID()
        XCTAssertTrue(session.acquire(mic, kind: .recording, onRetired: { retired += 1 }))
        session.routeChanged(deviceRemoved: false)
        XCTAssertFalse(session.contains(mic), "AirPods connecting would leave dictation stalled on the old route")
        XCTAssertEqual(retired, 1); XCTAssertEqual(releases, 1)
        XCTAssertFalse(session.release(mic)); XCTAssertEqual(releases, 1)
        let removed = UUID()
        XCTAssertTrue(session.acquire(removed, kind: .recording, onRetired: { retired += 1 }))
        session.routeChanged(deviceRemoved: true)
        XCTAssertFalse(session.contains(removed)); XCTAssertEqual(retired, 2); XCTAssertEqual(releases, 2)
        let mac = UUID()
        XCTAssertTrue(session.acquire(mac, kind: .macAudio, onRetired: {}))
        session.beginInterruption(); session.routeChanged(deviceRemoved: true)
        XCTAssertFalse(session.isInterrupted, "the last owner's retirement ends the interruption")
        XCTAssertEqual(releases, 3)
    }

    func testDuplicateOwnerCannotChangeKindAndRegistryIsBounded() {
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let id = UUID()
        XCTAssertTrue(session.acquire(id, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.acquire(id, kind: .recording, onRetired: {}))
        for _ in 0..<7 { XCTAssertTrue(session.acquire(UUID(), kind: .macAudio, onRetired: {})) }
        XCTAssertFalse(session.acquire(UUID(), kind: .macAudio, onRetired: {}))
    }
    func testTemporaryInterruptionResumesOnlySameOptedInOwnerAndRejectsNewAdmission() {
        var events: [String] = []
        let session = PhoneMediaSession(backend: .init(configure: { _ in events.append("configure") },
            activate: { events.append("activate") }, deactivate: { events.append("deactivate") }))
        let owner = UUID()
        XCTAssertTrue(session.acquire(owner, kind: .macAudio, onRetired: { events.append("retire") },
            onSuspended: { events.append("suspend") }, onResumed: { events.append("resume"); return true }))
        session.beginInterruption(); session.beginInterruption()
        XCTAssertTrue(session.contains(owner)); XCTAssertTrue(session.isInterrupted)
        XCTAssertFalse(session.acquire(UUID(), kind: .macAudio, onRetired: {}))
        XCTAssertEqual(events, ["configure", "activate", "suspend"])
        session.endInterruption(shouldResume: true)
        XCTAssertFalse(session.isInterrupted); XCTAssertTrue(session.contains(owner))
        XCTAssertEqual(events, ["configure", "activate", "suspend", "activate", "resume"])
        session.release(owner)
    }
    func testLateInterruptionEndCannotReviveTerminalOrReleasedPlaybackOwner() {
        for terminal in [true, false] {
            var resumes = 0, activations = 0
            let session = PhoneMediaSession(backend: .init(configure: { _ in },
                activate: { activations += 1 }, deactivate: {}))
            let old = UUID()
            XCTAssertTrue(session.acquire(old, kind: .macAudio, onRetired: {}, onResumed: { resumes += 1; return true }))
            session.beginInterruption()
            if terminal { session.retireAll() } else { session.release(old) }
            session.endInterruption(shouldResume: true)
            XCTAssertFalse(session.contains(old)); XCTAssertEqual(resumes, 0); XCTAssertEqual(activations, 1)
            let next = UUID(); XCTAssertTrue(session.acquire(next, kind: .macAudio, onRetired: {}))
            session.endInterruption(shouldResume: true)
            XCTAssertTrue(session.contains(next)); XCTAssertEqual(resumes, 0); XCTAssertEqual(activations, 2)
            session.release(next)
        }
    }
    func testNoResumeOptionRecordingAndExpiredConsumerRemainTerminal() {
        for kind in [PhoneMediaSession.Kind.macAudio, .recording] {
            var retired = 0, resumed = 0
            let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
            let id = UUID()
            XCTAssertTrue(session.acquire(id, kind: kind, onRetired: { retired += 1 }, onResumed: { resumed += 1; return true }))
            session.beginInterruption(); session.endInterruption(shouldResume: false)
            XCTAssertFalse(session.contains(id)); XCTAssertEqual(retired, 1); XCTAssertEqual(resumed, 0)
        }
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let expired = UUID(); var retired = 0
        XCTAssertTrue(session.acquire(expired, kind: .pictureInPicture, onRetired: { retired += 1 }, onResumed: { false }))
        session.beginInterruption(); session.endInterruption(shouldResume: true)
        XCTAssertFalse(session.contains(expired)); XCTAssertEqual(retired, 1)
    }
    func testResumeBackendReentrantRetirementCannotRestartOldConsumer() {
        var session: PhoneMediaSession!, activations = 0, resumed = 0
        session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {
            activations += 1
            if activations == 2 { session.retireAll() }
        }, deactivate: {}))
        let id = UUID()
        XCTAssertTrue(session.acquire(id, kind: .macAudio, onRetired: {}, onResumed: { resumed += 1; return true }))
        session.beginInterruption(); session.endInterruption(shouldResume: true)
        XCTAssertFalse(session.contains(id)); XCTAssertEqual(resumed, 0)
    }

    func testResumeCallbackReleaseDefersExactlyOneLastOwnerDeactivation() {
        var releases = 0
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: { releases += 1 }))
        let id = UUID()
        XCTAssertTrue(session.acquire(id, kind: .macAudio, onRetired: {}, onResumed: {
            session.release(id); return false
        }))
        session.beginInterruption(); session.endInterruption(shouldResume: true)
        XCTAssertFalse(session.contains(id)); XCTAssertEqual(releases, 1)
    }

}
