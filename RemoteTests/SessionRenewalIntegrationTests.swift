import XCTest
import Foundation
import CoreVideo
import WebRTC

private final class Trust: PairPersistence {
    var data: Data?
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

private final class FrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock(); count += 1; lock.unlock()
    }
}

/// End to end renewal against the real signaling service and real in-process WebRTC. The lease and
/// credential lifetimes are cut to a few seconds so several full periods fit in a test.
final class SessionRenewalIntegrationTests: XCTestCase {
    @MainActor
    private func waitFor(_ description: String, seconds: Double = 8, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    private func service(leaseMilliseconds: Int? = nil, relayTTLSeconds: Int? = nil) throws -> (Process, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        process.arguments = [root.appendingPathComponent("scripts/test-service.ts").path]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        if let leaseMilliseconds { environment["POCKETDESK_TEST_LEASE_MS"] = String(leaseMilliseconds) }
        if let relayTTLSeconds { environment["POCKETDESK_TEST_TURN_TTL_SECONDS"] = String(relayTTLSeconds) }
        process.environment = environment
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let text = String(data: bytes, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw RemoteError.invalidMessage
        }
        return (process, "ws://127.0.0.1:\(port)/signal")
    }

    @MainActor
    private func connectedPair(_ url: String, name: String, advertisesRenewal: Bool = true) async throws -> (RemoteCoordinator, RemoteCoordinator) {
        let host = RemoteCoordinator(isHost: true, store: Trust(), advertisesRenewal: advertisesRenewal)
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: Trust(), advertisesRenewal: advertisesRenewal)
        phone.allowLegacyPrivateRoute = true
        let invitation = try host.createPair(server: url, name: name)
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(invitation.code())
        try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
        try await waitFor("paired session connected: host \(host.status), phone \(phone.status)", seconds: 25) { host.connected && phone.connected }
        return (host, phone)
    }

    private func grayBuffer(_ value: Int32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), value, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    @MainActor
    func testTheSessionOutlivesSeveralLeasePeriodsBecauseBothAppsRenewAndTheMediaIsNeverRebuilt() async throws {
        let (service, url) = try service(leaseMilliseconds: 3000, relayTTLSeconds: 6); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Renewal Host")
        defer { host.stop(); phone.stop() }
        let hostMedia = try XCTUnwrap(host.media), phoneMedia = try XCTUnwrap(phone.media)

        let started = Date()
        var dropped: String?
        while Date().timeIntervalSince(started) < 10, dropped == nil {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            if !(host.connected && phone.connected) { dropped = "session dropped after \(elapsed) s: \(host.status) / \(phone.status)" }
            else if host.media !== hostMedia || phone.media !== phoneMedia { dropped = "media was rebuilt after \(elapsed) s" }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(dropped)

        XCTAssertGreaterThanOrEqual(host.renewalCount, 4, "the Mac renews about every 1.5 s")
        XCTAssertGreaterThanOrEqual(phone.renewalCount, 3)
        XCTAssertGreaterThanOrEqual(host.credentialRefreshCount, 2, "credentials refresh a third of the way through their 6 s life")
        XCTAssertGreaterThanOrEqual(phone.credentialRefreshCount, 2)
        XCTAssertGreaterThanOrEqual(hostMedia.iceConfigurationUpdates, 2, "fresh credentials were applied to the live connection")
        XCTAssertGreaterThanOrEqual(phoneMedia.iceConfigurationUpdates, 2)
        XCTAssertEqual(hostMedia.iceRestarts, 0, "a direct route does not need an ICE restart")
        XCTAssertEqual(phoneMedia.iceRestarts, 0)

        var received: RemoteAction?
        host.onControl = { data in received = try? JSONDecoder().decode(RemoteAction.self, from: data) }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "after three lease periods", key: "renew-1", epoch: 7)))
        try await waitFor("control message arrives after the lease period passed three times") { received != nil }
        XCTAssertEqual(received?.text, "after three lease periods")
        print(String(format: "RENEWAL RECEIPT: %.1f s connected, host renewals %d, credential refreshes %d, ICE config updates %d",
                     Date().timeIntervalSince(started), host.renewalCount, host.credentialRefreshCount, hostMedia.iceConfigurationUpdates))
    }

    @MainActor
    func testAppsThatDoNotRenewEndAtTheLeaseAndTheExistingReconnectRestoresTheSession() async throws {
        let (service, url) = try service(leaseMilliseconds: 8000); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Legacy Host", advertisesRenewal: false)
        defer { host.stop(); phone.stop() }
        let firstMedia = host.media

        try await waitFor("the room lease ends the session", seconds: 14) { !(host.connected && phone.connected) }
        try await waitFor("the bounded reconnect restores it with saved trust", seconds: 30) { host.connected && phone.connected }
        XCTAssertFalse(host.awaitingApproval)
        XCTAssertTrue(host.media !== firstMedia, "a fallback reconnect builds a new peer connection")
        XCTAssertEqual(host.renewalCount, 0)
        XCTAssertEqual(phone.renewalCount, 0)
    }

    @MainActor
    func testAnICERestartOnALiveSessionKeepsVideoAndControlFlowing() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Restart Host")
        defer { host.stop(); phone.stop() }
        let hostMedia = try XCTUnwrap(host.media), phoneMedia = try XCTUnwrap(phone.media)
        try await waitFor("remote video track negotiated") { phone.remoteVideo != nil }
        let counter = FrameCounter()
        let video = try XCTUnwrap(phone.remoteVideo)
        video.add(counter); defer { video.remove(counter) }
        let frames = [try grayBuffer(60), try grayBuffer(190)]
        var pushed = 0
        func push(seconds: Double) async throws {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                hostMedia.pushFrame(frames[pushed % 2], timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                pushed += 1
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        try await push(seconds: 1.5)
        try await waitFor("video flows before the restart") { counter.frames > 0 }
        XCTAssertEqual(hostMedia.remoteDescriptionsApplied, 1, "the host applied the phone's answer")
        XCTAssertEqual(phoneMedia.remoteDescriptionsApplied, 1, "the phone applied the host's offer")

        let framesBefore = counter.frames
        XCTAssertTrue(hostMedia.restartICE())
        var dropped: String?
        let restartStarted = Date()
        while Date().timeIntervalSince(restartStarted) < 4, dropped == nil {
            try await push(seconds: 0.2)
            if !(host.connected && phone.connected) { dropped = "session dropped during the restart: \(host.status) / \(phone.status)" }
        }
        XCTAssertNil(dropped)
        XCTAssertEqual(hostMedia.remoteDescriptionsApplied, 2, "the phone's answer to the restart offer was applied")
        XCTAssertEqual(phoneMedia.remoteDescriptionsApplied, 2, "the phone applied the restart offer")
        XCTAssertEqual(hostMedia.iceRestarts, 1)
        XCTAssertEqual(phoneMedia.iceRestarts, 1)
        XCTAssertGreaterThan(counter.frames, framesBefore + 10, "video kept flowing across the restart")
        XCTAssertTrue(host.media === hostMedia && phone.media === phoneMedia)
        XCTAssertTrue(host.diagnostics.hasPrefix("Direct"), host.diagnostics)

        var received: RemoteAction?
        host.onControl = { data in received = try? JSONDecoder().decode(RemoteAction.self, from: data) }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "after the restart", key: "restart-1", epoch: 9)))
        try await waitFor("control message arrives after the restart") { received != nil }
        XCTAssertEqual(received?.text, "after the restart")
    }

    @MainActor
    func testRefreshedCredentialsOnARelayedRouteRestartIceEveryTimeAndTheSessionSurvivesAllOfThem() async throws {
        let (service, url) = try service(leaseMilliseconds: 6000, relayTTLSeconds: 6); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Relay Refresh Host")
        defer { host.stop(); phone.stop() }
        let hostMedia = try XCTUnwrap(host.media), phoneMedia = try XCTUnwrap(phone.media)
        hostMedia.routeOverrideForTesting = "Relay"
        try await waitFor("remote video track negotiated") { phone.remoteVideo != nil }
        let counter = FrameCounter()
        let video = try XCTUnwrap(phone.remoteVideo)
        video.add(counter); defer { video.remove(counter) }
        let frames = [try grayBuffer(70), try grayBuffer(200)]

        var pushed = 0
        var dropped: String?
        let started = Date()
        while Date().timeIntervalSince(started) < 9, dropped == nil {
            hostMedia.pushFrame(frames[pushed % 2], timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            pushed += 1
            if !(host.connected && phone.connected) { dropped = "session dropped after \(Date().timeIntervalSince(started)) s: \(host.status) / \(phone.status)" }
            else if host.media !== hostMedia || phone.media !== phoneMedia { dropped = "media was rebuilt" }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(dropped)
        XCTAssertGreaterThanOrEqual(host.credentialRefreshCount, 3)
        XCTAssertGreaterThanOrEqual(host.iceRestartCount, 3, "a relayed route restarts ICE after each credential refresh")
        XCTAssertGreaterThanOrEqual(hostMedia.iceRestarts, host.iceRestartCount)
        try await waitFor("the phone answered every restart", seconds: 4) {
            phoneMedia.iceRestarts == hostMedia.iceRestarts && phoneMedia.remoteDescriptionsApplied == hostMedia.remoteDescriptionsApplied
        }
        XCTAssertGreaterThan(counter.frames, 30, "video kept flowing across the restarts")

        var received: RemoteAction?
        host.onControl = { data in received = try? JSONDecoder().decode(RemoteAction.self, from: data) }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "after the relayed refreshes", key: "relay-1", epoch: 11)))
        try await waitFor("control message arrives after repeated restarts") { received != nil }
        print("RELAY REFRESH RECEIPT: \(host.credentialRefreshCount) refreshes, \(host.iceRestartCount) ICE restarts, \(counter.frames) frames, no drop")
    }
}
