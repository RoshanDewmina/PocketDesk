import XCTest
import Foundation

private final class SharedTrust: PairPersistence {
    var data: Data?
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

/// A crashed or hung Mac app is relaunched by the watchdog as a new process with the same saved
/// pairing. These tests use the real signaling service and native WebRTC.
final class HostRestartIntegrationTests: XCTestCase {
    @MainActor
    private func waitFor(_ description: String, seconds: Double = 8, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    private func service() throws -> (Process, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        process.arguments = [root.appendingPathComponent("scripts/test-service.ts").path]
        process.currentDirectoryURL = root; process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let text = String(data: bytes, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw RemoteError.invalidMessage
        }
        return (process, "ws://127.0.0.1:\(port)/signal")
    }

    @MainActor
    func testPhoneReconnectsToARelaunchedHostWithTheSamePairing() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostTrust = SharedTrust()
        let host = RemoteCoordinator(isHost: true, store: hostTrust)
        host.allowLegacyPrivateRoute = true
        // Same shape as the app's phone coordinator, scaled down: default window 3.1 s, extended ~9 s.
        let phone = RemoteCoordinator(isHost: false, store: SharedTrust(), retryBaseNanoseconds: 100_000_000,
                                      sessionLossRetryLimit: 24, maximumRetryDelayNanoseconds: 400_000_000)
        phone.allowLegacyPrivateRoute = true
        defer { host.stop(); phone.stop() }
        let invitation = try host.createPair(server: url, name: "Relaunch Mac")
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(invitation.code())
        try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
        try await waitFor("paired session connected", seconds: 25) { host.connected && phone.connected }

        // The host process dies: its signaling socket closes and nothing else runs.
        host.stop()
        try await waitFor("phone noticed the Mac app went away") { !phone.connected && phone.status.contains("retrying") }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertTrue(phone.isRunning, "A lost live session keeps retrying past the ordinary retry window")

        // The watchdog relaunches a new process that restores the same pairing from the Keychain.
        let relaunched = RemoteCoordinator(isHost: true, store: hostTrust)
        relaunched.allowLegacyPrivateRoute = true
        defer { relaunched.stop() }
        relaunched.restore()
        relaunched.start()
        try await waitFor("phone reconnected without anyone touching either device: \(phone.status)", seconds: 25) {
            relaunched.connected && phone.connected
        }
        XCTAssertFalse(relaunched.awaitingApproval, "A relaunch never requires re-pairing")
    }

    @MainActor
    func testOrdinaryConnectFailuresKeepTheShortRetryWindow() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let invitation = try HostPair.create(server: url, name: "Absent Mac").rotated().invitation
        let phoneTrust = SharedTrust()
        try phoneTrust.save(invitation)
        let phone = RemoteCoordinator(isHost: false, store: phoneTrust, retryBaseNanoseconds: 50_000_000,
                                      sessionLossRetryLimit: 24, maximumRetryDelayNanoseconds: 400_000_000)
        phone.allowLegacyPrivateRoute = true
        defer { phone.stop() }
        phone.restore()
        XCTAssertEqual(phone.invitation?.version, 1, "Ordinary connect uses saved trust rather than fresh enrollment")
        phone.start()
        try await waitFor("a Mac that never answered is reported within the normal window", seconds: 6) {
            !phone.isRunning
        }
        XCTAssertFalse(phone.status.contains("retrying"))
    }

    @MainActor
    func testRelaunchedHostWaitsOutItsPredecessorsRoom() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let trust = SharedTrust()
        let predecessor = RemoteCoordinator(isHost: true, store: trust)
        predecessor.allowLegacyPrivateRoute = true
        defer { predecessor.stop() }
        let saved = try HostPair.create(server: url, name: "Predecessor").rotated()
        try trust.save(saved)
        predecessor.restore()
        XCTAssertEqual(predecessor.hostPair?.paired, true)
        XCTAssertEqual(predecessor.invitation?.version, 1)
        predecessor.start()
        try await waitFor("predecessor registered") { predecessor.hostRegistered }

        let relaunched = RemoteCoordinator(isHost: true, store: trust, retryBaseNanoseconds: 100_000_000)
        relaunched.allowLegacyPrivateRoute = true
        defer { relaunched.stop() }
        relaunched.restore()
        relaunched.start()
        try await waitFor("the room is still held, so the relaunch waits instead of failing") {
            relaunched.status.contains("retrying")
        }
        XCTAssertTrue(relaunched.isRunning)
        predecessor.stop()
        try await waitFor("relaunched host registered once the old room closed") { relaunched.hostRegistered }
        XCTAssertFalse(relaunched.awaitingApproval)
        XCTAssertEqual(relaunched.invitation, saved.invitation)
    }
}
