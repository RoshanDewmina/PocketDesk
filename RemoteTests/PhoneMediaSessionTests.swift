import XCTest

@MainActor
final class PhoneMediaSessionTests: XCTestCase {
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

    func testDuplicateOwnerCannotChangeKindAndRegistryIsBounded() {
        let session = PhoneMediaSession(backend: .init(configure: { _ in }, activate: {}, deactivate: {}))
        let id = UUID()
        XCTAssertTrue(session.acquire(id, kind: .pictureInPicture, onRetired: {}))
        XCTAssertFalse(session.acquire(id, kind: .recording, onRetired: {}))
        for _ in 0..<7 { XCTAssertTrue(session.acquire(UUID(), kind: .macAudio, onRetired: {})) }
        XCTAssertFalse(session.acquire(UUID(), kind: .macAudio, onRetired: {}))
    }
}
