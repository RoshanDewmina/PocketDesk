import XCTest
import Foundation

/// An agent alert over a real session: a real signaling service and two real WebRTC peers, the Mac
/// sending and the phone receiving on the ordered control channel, as it does in a live session.
final class AgentAlertSessionTests: XCTestCase {
    @MainActor
    private func waitFor(_ description: String, seconds: Double = 8, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    private func startService() throws -> (Process, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        process.arguments = [root.appendingPathComponent("scripts/test-service.ts").path]
        process.currentDirectoryURL = root
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let text = String(data: bytes, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw RemoteError.invalidMessage
        }
        return (process, "ws://127.0.0.1:\(port)/signal")
    }

    @MainActor
    func testAnAlertTravelsFromTheMacToThePhoneOnTheRealControlChannel() async throws {
        let (service, url) = try startService()
        defer { service.terminate() }
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore())
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore())
        phone.allowLegacyPrivateRoute = true
        defer { host.stop(); phone.stop() }

        let original = try host.createPair(server: url, name: "Alert Mac")
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(original.code())
        try await waitFor("host asks for approval") { host.awaitingApproval }
        host.approve()
        try await waitFor("both control channels connected: \(host.status), \(phone.status)", seconds: 25) {
            host.connected && phone.connected
        }

        var received: [RemoteAction] = []
        phone.onControl = { data in
            if let action = try? JSONDecoder().decode(RemoteAction.self, from: data) { received.append(action) }
        }
        let frame = AgentAlertFrame(id: AgentAlert.makeID(), kind: .claudeCode, event: .needsUser, raisedAt: Date())
        XCTAssertTrue(host.sendControl(RemoteAction(action: "capture", x: 1, epoch: 3, agentAlert: frame)))
        try await waitFor("the alert arrived on the phone's control channel") { received.contains { $0.agentAlert != nil } }

        let arrived = try XCTUnwrap(received.first { $0.agentAlert != nil })
        XCTAssertEqual(arrived.action, "capture", "It rides on the status message the Mac already sends")
        XCTAssertEqual(arrived.agentAlert, frame)
        XCTAssertNoThrow(try arrived.validate(), "The phone's own validator accepts what the Mac sends")
        XCTAssertTrue(host.connected && phone.connected, "An alert never disturbs the session")

        XCTAssertTrue(host.sendControl(RemoteAction(action: "capture", x: 1, epoch: 3)))
        try await waitFor("a plain status still arrives") { received.contains { $0.action == "capture" && $0.agentAlert == nil } }
    }
}
