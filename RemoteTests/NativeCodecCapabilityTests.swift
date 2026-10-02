import CoreMedia
import XCTest

final class NativeCodecCapabilityTests: XCTestCase {
    func testUnfinishedProbeReadDoesNotJoinAndStartsOnlyOnce() async {
        let entered = expectation(description: "background probe entered")
        let release = DispatchSemaphore(value: 0)
        let probe = NativeCapabilityProbe {
            entered.fulfill()
            release.wait()
            return true
        }
        defer { release.signal() }
        XCTAssertFalse(probe.snapshot)
        await fulfillment(of: [entered], timeout: 1)
        await MainActor.run {
            for _ in 0..<100 { XCTAssertFalse(probe.snapshot) }
        }
    }

    func testAsyncReadinessReturnsConservativeAtDeadlineAndPublishesLateSuccess() async {
        let release = DispatchSemaphore(value: 0)
        let probe = NativeCapabilityProbe { release.wait(); return true }
        defer { release.signal() }
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = await probe.ready(timeout: 0.02)
        XCTAssertFalse(timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        release.signal()
        let ready = await probe.ready()
        XCTAssertTrue(ready)
        XCTAssertTrue(probe.snapshot)
    }

    func testReadinessCompletesWhenProbeFinishesWithoutBlockingMain() async {
        let entered = expectation(description: "background probe entered")
        let release = DispatchSemaphore(value: 0)
        let probe = NativeCapabilityProbe { entered.fulfill(); release.wait(); return true }
        defer { release.signal() }
        let preparation = Task { await probe.ready() }
        await fulfillment(of: [entered], timeout: 1)
        await MainActor.run { _ = release.signal() }
        let ready = await preparation.value
        XCTAssertTrue(ready)
    }

    func testExpiredAbsoluteDeadlineRejectsAlreadyPublishedLateResult() async {
        let expiredDeadline = DispatchTime.now() - 0.01
        let probe = NativeCapabilityProbe { true }
        let ready = await probe.ready()
        XCTAssertTrue(ready)
        let expired = await probe.ready(deadline: expiredDeadline)
        XCTAssertFalse(expired, "completion before waiter registration must still respect that waiter's deadline")
        XCTAssertTrue(probe.snapshot, "the result remains valid for a later session")
    }

    func testAsyncCapabilitySwitchDefaultsOnAndExplicitNoRestoresLegacyMode() throws {
        let suite = "NativeCodecCapabilityTests.switch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NativeVideoCapabilitySnapshot.isEnabled(defaults: defaults))
        defaults.set(false, forKey: "PocketDeskAsyncCapabilitySnapshot")
        XCTAssertFalse(NativeVideoCapabilitySnapshot.isEnabled(defaults: defaults))
        defaults.set(true, forKey: "PocketDeskAsyncCapabilitySnapshot")
        XCTAssertTrue(NativeVideoCapabilitySnapshot.isEnabled(defaults: defaults))
    }

    func testExplicitNoUsesLegacyReadInsteadOfConservativeSnapshot() {
        let probe = NativeCapabilityProbe { false }
        var legacyCalls = 0
        XCTAssertFalse(NativeVideoCapabilitySnapshot.read(probe: probe, legacy: { legacyCalls += 1; return true }, enabled: true))
        XCTAssertEqual(legacyCalls, 0)
        XCTAssertTrue(NativeVideoCapabilitySnapshot.read(probe: probe, legacy: { legacyCalls += 1; return true }, enabled: false))
        XCTAssertEqual(legacyCalls, 1)
    }

    func testSnapshotReadinessUsesOneDeadlineForAllUnfinishedRoles() async {
        let release = DispatchSemaphore(value: 0)
        let probes = NativeVideoCapabilityProbes(
            level52: { release.wait(); return true },
            hevcDecode: { release.wait(); return true },
            hevcEncode: { release.wait(); return true })
        defer { for _ in 0..<3 { release.signal() } }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = await probes.ready(isHost: true, timeout: 0.02)
        XCTAssertEqual(snapshot, .conservative)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2, "deadlines run concurrently, not per-role serial waits")
    }

    #if DEBUG
    func testMainPeerInitializationDoesNotJoinUnfinishedCapabilityProbes() async throws {
        let timingEnabled = ProcessInfo.processInfo.environment["FARSIDE_CAPABILITY_TIMING_TESTS"] == "1"
        let testingDirectory = "/Users/roshansilva/Documents/Codex/2026-10-01/testing"
        let quietGranted = (try? FileManager.default.contentsOfDirectory(atPath: testingDirectory))?
            .contains(where: { $0.hasPrefix("QUIET-GRANTED-") }) == true
        guard timingEnabled, quietGranted else {
            throw XCTSkip("native Peer init timing requires FARSIDE_CAPABILITY_TIMING_TESTS=1 and a granted QUIET window")
        }
        guard NativeVideoCapabilitySnapshot.enabled else {
            throw XCTSkip("launch with PocketDeskAsyncCapabilitySnapshot ON for the async native Peer timing fixture")
        }
        let entered = expectation(description: "all injected probes entered")
        entered.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        let blocking: @Sendable () -> Bool = { entered.fulfill(); release.wait(); return true }
        let probes = NativeVideoCapabilityProbes(level52: blocking, hevcDecode: blocking, hevcEncode: blocking)
        let previous = NativeVideoCapabilityProbes.installForTesting(probes)
        defer {
            _ = NativeVideoCapabilityProbes.installForTesting(previous)
            for _ in 0..<3 { release.signal() }
        }
        await MainActor.run {
            // Warm WebRTC's one-time runtime separately from the capability-read assertion.
            let warmPeer = PeerMedia(isHost: false, servers: [], nativeDesktopCodecs: false, hevc: false, hevc444: false)
            warmPeer.close()
        }
        _ = probes.snapshot(isHost: true)
        await fulfillment(of: [entered], timeout: 1)
        await MainActor.run {
            let start = ProcessInfo.processInfo.systemUptime
            let peer = PeerMedia(isHost: false, servers: [], hevc444: false)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            peer.close()
            XCTAssertLessThan(elapsed, 0.005, "an unfinished probe must never be synchronously joined from peer init")
        }
    }
    #endif

    func testEmbeddedFixtureIsHighLevel52At4K() throws {
        let description = try XCTUnwrap(NativeCodecCapability.fixtureDescription())
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(dimensions.width, 3840)
        XCTAssertEqual(dimensions.height, 2160)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
    }

    func testProbeReturnsCachedResult() async {
        _ = await NativeVideoCapabilityProbes.current.level52.ready()
        let first = NativeCodecCapability.supportsLevel52
        XCTAssertEqual(first, NativeCodecCapability.supportsLevel52)
        #if targetEnvironment(simulator)
        XCTAssertFalse(first)
        XCTAssertEqual(NativeCodecCapability.outcome, .simulator)
        #else
        // Readiness can return its conservative deadline just before the legacy worker records
        // its own timeout. A nil outcome still denotes an unfinished background probe.
        XCTAssertNotEqual(NativeCodecCapability.outcome, .simulator)
        #endif
        XCTAssertFalse(NativeCodecCapability.outcomeDescription.isEmpty)
    }

    func testOnlyPositiveResultsAreCachedPerSystemAndModel() throws {
        let suite = "NativeCodecCapabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NativeCodecCapability.cacheDefaultsKey
        XCTAssertTrue(key.hasPrefix("PocketDeskLevel52Probe."))
        XCTAssertTrue(key.contains(NativeCodecCapability.systemAndModel))
        XCTAssertFalse(NativeCodecCapability.systemAndModel.contains(" "))
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key))
        NativeCodecCapability.storeResult(false, defaults: defaults, key: key)
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key), "a failed probe is retried next launch")
        NativeCodecCapability.storeResult(true, defaults: defaults, key: key)
        XCTAssertEqual(NativeCodecCapability.cachedResult(defaults: defaults, key: key), true)
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key + ".other-os"), "an OS or model change re-probes")
    }
}
