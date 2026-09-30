import XCTest
import Foundation

/// The Mac's registration with the service must stay true: a socket that died silently is found by
/// the keepalive, reported as reconnecting rather than Ready, and retried for as long as sharing is on.
@MainActor
final class HostSignalingRecoveryTests: XCTestCase {
    private func makeHost(retriesIndefinitely: Bool = true, base: UInt64 = 5_000_000,
                          maximum: UInt64? = 20_000_000) throws -> (RemoteCoordinator, ScriptedSignaling) {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        let signaling = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: base,
                                     maximumRetryDelayNanoseconds: maximum, retriesIndefinitely: retriesIndefinitely,
                                     registrationStableNanoseconds: 60_000_000_000, signaling: signaling,
                                     renewalScheduler: ManualScheduler())
        host.allowLegacyPrivateRoute = true
        host.restore()
        return (host, signaling)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private func register(_ signaling: ScriptedSignaling) {
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
    }

    func testASilentlyDeadSocketStopsBeingReadyAndReRegisters() async throws {
        let (host, signaling) = try makeHost()
        host.start()
        register(signaling)
        XCTAssertTrue(host.hostRegistered)
        XCTAssertFalse(host.reconnecting)

        signaling.serverCloses(reason: SignalingKeepalive.Failure.timeout.rawValue)
        XCTAssertFalse(host.hostRegistered, "a Mac whose keepalive failed is not registered, so it cannot claim Ready")
        XCTAssertTrue(host.reconnecting)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.status, "Connection interrupted · retrying…")
        XCTAssertEqual(host.signalingLossReason, "keepalive timed out")

        let reconnected = await eventually { signaling.connects.count == 2 }
        XCTAssertTrue(reconnected)
        register(signaling)
        XCTAssertTrue(host.hostRegistered)
        XCTAssertFalse(host.reconnecting)
        host.stop()
    }

    func testAHostKeepsRetryingPastTheRetryLimitWhileSharingIsOn() async throws {
        let (host, signaling) = try makeHost()
        host.start()
        for attempt in 1...8 {
            signaling.serverCloses()
            let retried = await eventually { signaling.connects.count == attempt + 1 }
            XCTAssertTrue(retried, "attempt \(attempt) was never retried")
        }
        XCTAssertTrue(host.isRunning, "a sharing Mac never gives up on the service by itself")
        XCTAssertTrue(host.reconnecting)
        XCTAssertFalse(host.hostRegistered)
        host.stop()
        XCTAssertFalse(host.reconnecting)
        XCTAssertFalse(host.isRunning)
    }

    func testWithoutIndefiniteRetryTheBudgetStillEnds() async throws {
        let (host, signaling) = try makeHost(retriesIndefinitely: false)
        host.start()
        for attempt in 1...2 {
            signaling.serverCloses()
            let retried = await eventually { signaling.connects.count == attempt + 1 }
            XCTAssertTrue(retried)
        }
        signaling.serverCloses()
        XCTAssertFalse(host.isRunning, "phones keep their bounded retry")
        XCTAssertFalse(host.reconnecting)
        XCTAssertEqual(host.status, "Connection lost. Tap Connect to try again.")
    }

    func testANetworkChangeSkipsTheRemainingBackoff() throws {
        let (host, signaling) = try makeHost(base: 30_000_000_000, maximum: 60_000_000_000)
        host.start()
        signaling.serverCloses()
        XCTAssertEqual(signaling.connects.count, 1, "the first retry waits out its backoff")
        host.networkPathChanged()
        XCTAssertEqual(signaling.connects.count, 2, "a new path is worth trying at once")
        XCTAssertTrue(host.reconnecting, "still reconnecting until the service registers the Mac")
        host.stop()
    }

    func testANetworkChangeOrWakeChecksARegisteredSocketWithoutDroppingIt() throws {
        let (host, signaling) = try makeHost()
        host.start()
        register(signaling)
        host.networkPathChanged()
        XCTAssertEqual(signaling.livenessChecks, 1)
        host.checkSignalingLiveness()
        XCTAssertEqual(signaling.livenessChecks, 2)
        XCTAssertEqual(signaling.connects.count, 1, "a live registration is probed, not torn down")
        XCTAssertTrue(host.hostRegistered)

        host.stop()
        host.networkPathChanged()
        host.checkSignalingLiveness()
        XCTAssertEqual(signaling.livenessChecks, 2, "a stopped Mac does nothing on network changes")
        XCTAssertEqual(signaling.connects.count, 1)
    }

    func testTheHostBackoffIsCappedAtAMinute() {
        let minute: UInt64 = 60_000_000_000
        XCTAssertEqual(RetrySchedule.delay(attempt: 1, base: RemoteCoordinator.hostRetryBaseNanoseconds,
                                           maximum: RemoteCoordinator.hostMaximumRetryDelayNanoseconds), 500_000_000)
        XCTAssertEqual(RetrySchedule.delay(attempt: 50, base: RemoteCoordinator.hostRetryBaseNanoseconds,
                                           maximum: RemoteCoordinator.hostMaximumRetryDelayNanoseconds), minute)
    }
}

@MainActor
final class NetworkPathWatcherTests: XCTestCase {
    func testOnlyARouteChangingUpdateIsReported() {
        let watcher = NetworkPathWatcher()
        var changes = 0
        watcher.onChange = { changes += 1 }
        let wifi = NetworkPathSignature(satisfied: true, interfaces: ["en0:wifi"])
        watcher.observe(wifi)
        XCTAssertEqual(changes, 0, "the first reading is the starting point, not a change")
        watcher.observe(wifi)
        watcher.observe(wifi)
        XCTAssertEqual(changes, 0, "address republishing with the same route is not a change")
        watcher.observe(NetworkPathSignature(satisfied: true, interfaces: ["en0:wifi", "utun4:other"]))
        XCTAssertEqual(changes, 1, "a VPN coming up changes the route")
        watcher.observe(NetworkPathSignature(satisfied: false, interfaces: []))
        watcher.observe(wifi)
        XCTAssertEqual(changes, 3)
    }
}
