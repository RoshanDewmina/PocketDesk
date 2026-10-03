import CoreMedia
import WebRTC
import XCTest

final class NativeCodecCapabilityTests: XCTestCase {
    func testConnectDeadlineSnapshotCannotUpgradeFactoriesAfterLateProbeCompletion() async {
        let entered = expectation(description: "Connect probes started")
        entered.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        let blocking: @Sendable () -> Bool = { entered.fulfill(); release.wait(); return true }
        let probes = NativeVideoCapabilityProbes(level52: blocking, hevcDecode: blocking, hevcEncode: blocking)
        defer { for _ in 0..<3 { release.signal() } }
        let preparation = Task { await probes.ready(isHost: true, timeout: 0.02) }
        await fulfillment(of: [entered], timeout: 1)
        let snapshot = await preparation.value
        XCTAssertEqual(snapshot, .conservative)
        let encoder = PocketDeskVideoEncoderFactory(capabilitySnapshot: snapshot)
        let decoder = PocketDeskVideoDecoderFactory(capabilitySnapshot: snapshot)
        let encoderCodecs = encoder.supportedCodecs().map(\.parameters)
        let decoderCodecs = decoder.supportedCodecs().map(\.parameters)
        for _ in 0..<3 { release.signal() }
        let later = await probes.ready(isHost: true)
        XCTAssertTrue(later.supportsLevel52)
        XCTAssertTrue(later.supportsHEVCDecode); XCTAssertTrue(later.supportsHEVCEncode)
        XCTAssertEqual(encoder.supportedCodecs().map(\.parameters), encoderCodecs)
        XCTAssertEqual(decoder.supportedCodecs().map(\.parameters), decoderCodecs)
        XCTAssertFalse(NativeHEVCCapability.permits(isHost: true, snapshot: snapshot))
        XCTAssertFalse(NativeHEVC444Capability.permits(isHost: true, snapshot: snapshot))
    }

    func testPhoneReadinessDoesNotJoinHostEncoderProbe() async {
        let release = DispatchSemaphore(value: 0)
        let probes = NativeVideoCapabilityProbes(level52: { true }, hevcDecode: { true },
            hevcEncode: { release.wait(); return true })
        defer { release.signal() }
        let phone = await probes.ready(isHost: false)
        XCTAssertTrue(phone.supportsLevel52); XCTAssertTrue(phone.supportsHEVCDecode)
        XCTAssertFalse(phone.supportsHEVCEncode)
        let host = await probes.ready(isHost: true, timeout: 0.02)
        XCTAssertTrue(host.supportsLevel52); XCTAssertTrue(host.supportsHEVCDecode)
        XCTAssertFalse(host.supportsHEVCEncode)
        release.signal()
        let readyHost = await probes.ready(isHost: true)
        XCTAssertTrue(readyHost.supportsHEVCEncode)
        XCTAssertEqual(phone.supportsHEVCEncode, false, "A later host result cannot mutate the phone snapshot")
    }

    #if DEBUG
    @MainActor
    func testStoppedOrRetiredConnectCannotCreatePeerFromLateCapabilityResult() async throws {
        guard NativeVideoCapabilitySnapshot.enabled else {
            throw XCTSkip("Run this Connect retirement fixture with PocketDeskAsyncCapabilitySnapshot ON")
        }
        for stopAll in [true, false] {
            let entered = expectation(description: "Host capability probes entered")
            entered.expectedFulfillmentCount = 3
            let release = DispatchSemaphore(value: 0)
            let blocking: @Sendable () -> Bool = { entered.fulfill(); release.wait(); return true }
            let probes = NativeVideoCapabilityProbes(level52: blocking, hevcDecode: blocking, hevcEncode: blocking)
            let previous = NativeVideoCapabilityProbes.installForTesting(probes)
            defer {
                _ = NativeVideoCapabilityProbes.installForTesting(previous)
                for _ in 0..<3 { release.signal() }
            }
            let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Capability fixture").rotated()
            let store = MemoryPairStore(); try store.save(pair)
            let signaling = ScriptedSignaling()
            let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 0, signaling: signaling)
            host.allowLegacyPrivateRoute = true
            host.restore(); host.start()
            defer { host.stop() }
            signaling.deliver(RelayMessage(type: "registered", role: "host"))
            signaling.deliver(RelayMessage(type: "ice", servers: []))
            let cipher = try SignalCipher(key: pair.invitation.key, room: pair.invitation.room)
            let request = try SecureRandom.token()
            func seal(_ kind: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
                RelayMessage(type: "signal", payload: try cipher.seal(
                    ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: "client"))
            }
            signaling.deliver(RelayMessage(type: "peer", online: true))
            signaling.deliver(try seal("request"))
            let challenge = try cipher.open(try XCTUnwrap(signaling.sent.last?.payload), sender: "host")
            signaling.deliver(try seal("proof", session: challenge.session))
            signaling.deliver(try seal("acceptedAck", session: challenge.session, sequence: 1))
            await fulfillment(of: [entered], timeout: 1)
            XCTAssertNil(host.media, "Connect suspends instead of constructing a peer from unfinished evidence")
            let candidate = MediaSignal(kind: "candidate", candidate: "candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host", mid: "0", line: 0)
            signaling.deliver(try seal("media", session: challenge.session, sequence: 2, body: JSONEncoder().encode(candidate)))
            XCTAssertTrue(host.isRunning, "An authenticated early remote candidate uses the bounded preparation queue")
            if stopAll { host.stop() }
            else { signaling.deliver(RelayMessage(type: "peer", online: false)) }
            for _ in 0..<3 { release.signal() }
            _ = await probes.ready(isHost: true)
            // Let the production readiness continuation return through MainActor after retirement.
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertNil(host.media, "Old readiness must not recreate a retired peer")
            XCTAssertFalse(host.connected)
            if stopAll { XCTAssertFalse(host.isRunning) }
            else { XCTAssertTrue(host.isRunning); XCTAssertTrue(host.hostRegistered) }
        }
    }
    #endif

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
