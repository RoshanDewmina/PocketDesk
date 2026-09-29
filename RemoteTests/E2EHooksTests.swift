import XCTest
import Foundation

private final class E2EMemoryTrust: PairPersistence {
    var data: Data?
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

/// The E2E hooks are DEBUG-only and must refuse every half-configured or unsafe launch.
final class E2EHooksTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Launch gating

    func testOrdinaryLaunchIsNotE2E() throws {
        let options = E2ELaunchOptions(arguments: ["app"], environment: ["FARSIDE_E2E": "1"])
        XCTAssertFalse(options.requested)
        XCTAssertNil(try options.validatedCommon())
    }

    func testArgumentWithoutEnvironmentFlagIsRefused() {
        let options = E2ELaunchOptions(arguments: ["app", "--farside-e2e"],
                                       environment: ["FARSIDE_E2E_DIR": "/private/tmp/farside-e2e"])
        XCTAssertThrowsError(try options.validatedCommon())
    }

    func testDirectoryOutsideTheHarnessRootIsRefused() {
        for directory in ["/Users/Shared/farside-e2e", "relative/dir", "/private/tmp/other"] {
            let options = E2ELaunchOptions(arguments: ["--farside-e2e"],
                                           environment: ["FARSIDE_E2E": "1", "FARSIDE_E2E_DIR": directory])
            XCTAssertThrowsError(try options.validatedCommon(), directory)
        }
    }

    func testRunIdentifierMustBeSimple() {
        let options = E2ELaunchOptions(arguments: ["--farside-e2e"],
                                       environment: ["FARSIDE_E2E": "1", "FARSIDE_E2E_DIR": E2E.root,
                                                     "FARSIDE_E2E_RUN_ID": "../../etc"])
        XCTAssertThrowsError(try options.validatedCommon())
    }

    func testValidLaunchParsesDirectoryAndRun() throws {
        let options = E2ELaunchOptions(arguments: ["--farside-e2e"],
                                       environment: ["FARSIDE_E2E": "1", "FARSIDE_E2E_DIR": E2E.root,
                                                     "FARSIDE_E2E_RUN_ID": "run-42"])
        let common = try XCTUnwrap(options.validatedCommon())
        XCTAssertEqual(common.directory, E2E.root)
        XCTAssertEqual(common.runID, "run-42")
    }

    func testSignalingMustBeLoopback() throws {
        func options(_ url: String) -> E2ELaunchOptions {
            E2ELaunchOptions(arguments: ["--farside-e2e"], environment: ["FARSIDE_E2E_SIGNAL_URL": url])
        }
        XCTAssertEqual(try options("ws://127.0.0.1:18790/signal").validatedSignalURL(), "ws://127.0.0.1:18790/signal")
        XCTAssertNoThrow(try options("ws://localhost:9/signal").validatedSignalURL())
        for bad in ["wss://relay.example.com/signal", "ws://192.168.1.2:8787/signal",
                    "ws://127.0.0.1:8787/other", "http://127.0.0.1:8787/signal", ""] {
            XCTAssertThrowsError(try options(bad).validatedSignalURL(), bad)
        }
    }

    // MARK: One-time pairing token

    private func secrets(token: String?, mode: Int = 0o600) throws -> String {
        let directory = scratch.appendingPathComponent("secrets").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let token {
            let path = directory + "/" + E2E.tokenFileName
            FileManager.default.createFile(atPath: path, contents: Data((token + "\n").utf8),
                                           attributes: [.posixPermissions: mode])
            chmod(path, mode_t(mode))
        }
        return directory
    }

    func testTokenApprovesOnceAndIsConsumed() throws {
        let token = String(repeating: "ab", count: 32)
        let directory = try secrets(token: token)
        XCTAssertEqual(E2EPairingToken.consume(proof: Data(token.utf8), secretsDirectory: directory), .accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/" + E2E.tokenFileName))
        guard case .rejected = E2EPairingToken.consume(proof: Data(token.utf8), secretsDirectory: directory) else {
            return XCTFail("A consumed token must never approve a second phone")
        }
    }

    func testWrongMissingOrMalformedProofIsRejected() throws {
        let token = String(repeating: "cd", count: 32)
        let directory = try secrets(token: token)
        for proof in [Data(String(repeating: "ab", count: 32).utf8), Data("short".utf8), nil,
                      Data(String(repeating: "CD", count: 32).utf8)] {
            guard case .rejected = E2EPairingToken.consume(proof: proof, secretsDirectory: directory) else {
                return XCTFail("proof \(String(describing: proof)) must be rejected")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/" + E2E.tokenFileName),
                      "A failed attempt must not consume the token")
    }

    func testTokenFileMustBeOwnerOnly() throws {
        let token = String(repeating: "ef", count: 32)
        let directory = try secrets(token: token, mode: 0o644)
        guard case .rejected = E2EPairingToken.consume(proof: Data(token.utf8), secretsDirectory: directory) else {
            return XCTFail("A group/world-readable token file must be refused")
        }
    }

    func testSymlinkedTokenFileIsRefused() throws {
        let token = String(repeating: "12", count: 32)
        let directory = try secrets(token: nil)
        let real = scratch.appendingPathComponent("real-token").path
        FileManager.default.createFile(atPath: real, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.createSymbolicLink(atPath: directory + "/" + E2E.tokenFileName, withDestinationPath: real)
        guard case .rejected = E2EPairingToken.consume(proof: Data(token.utf8), secretsDirectory: directory) else {
            return XCTFail("A symlinked token must be refused")
        }
    }

    // MARK: Input fence

    private let window = CGRect(x: 200, y: 150, width: 1000, height: 600)

    private func environment(frontmost: Bool = true, pointer: CGPoint = CGPoint(x: 600, y: 400),
                             covering: String? = nil, running: Bool = true) -> HostE2EFenceEnvironment {
        HostE2EFenceEnvironment(testPadRunning: running, testPadFrontmost: frontmost,
                                testPadContent: running ? window : nil, pointer: pointer, coveringOwner: covering)
    }

    private func decide(_ action: RemoteAction, _ environment: HostE2EFenceEnvironment,
                        spaceKeys: Bool = false) -> HostE2EInputFence.Verdict {
        HostE2EInputFence.decide(action, held: false, allowSpaceKeys: spaceKeys, environment: environment)
    }

    func testMovesStayInsideTheTestPad() {
        XCTAssertEqual(decide(RemoteAction(action: "move", x: 10, y: -20), environment()), .allow)
        let clamped = decide(RemoteAction(action: "move", x: 5000, y: 0), environment())
        XCTAssertEqual(clamped, .adjust(dx: Double(window.maxX - HostE2EInputFence.edgeInset - 0.5 - 600), dy: 0))
        guard case .reject = decide(RemoteAction(action: "move", x: 1, y: 1), environment(frontmost: false)) else {
            return XCTFail("No motion while another app is frontmost")
        }
    }

    func testClampedRelativeMoveFromFarAwayStillAllowsClickAtAllEdges() {
        for coordinate in [20_000.125, -20_000.125] {
            var state = environment(pointer: CGPoint(x: coordinate, y: coordinate))
            guard case .adjust(let dx, let dy) = decide(RemoteAction(action: "move", x: 1, y: 1), state) else {
                return XCTFail("A distant pointer must be pulled into the pad")
            }
            // Exercise the same subtraction/addition round trip as actual relative injection.
            state.pointer.x += dx
            state.pointer.y += dy
            XCTAssertTrue(window.insetBy(dx: HostE2EInputFence.edgeInset, dy: HostE2EInputFence.edgeInset)
                .contains(state.pointer))
            XCTAssertEqual(decide(RemoteAction(action: "click"), state), .allow)
        }
    }

    func testPointerOutsideIsPulledIntoTheTestPad() {
        let outside = environment(pointer: CGPoint(x: 20, y: 20))
        guard case .adjust(let dx, let dy) = decide(RemoteAction(action: "move", x: 1, y: 1), outside) else {
            return XCTFail("The first move from outside must land inside the Test Pad")
        }
        XCTAssertEqual(20 + dx, Double(window.minX + HostE2EInputFence.edgeInset + 0.5), accuracy: 0.001)
        XCTAssertEqual(20 + dy, Double(window.minY + HostE2EInputFence.edgeInset + 0.5), accuracy: 0.001)
    }

    func testClicksNeedTheTestPadUnderAnUncoveredPointer() {
        for name in ["click", "right", "double", "dragDown", "scroll"] {
            XCTAssertEqual(decide(RemoteAction(action: name), environment()), .allow, name)
            guard case .reject = decide(RemoteAction(action: name), environment(pointer: CGPoint(x: 10, y: 10))),
                  case .reject = decide(RemoteAction(action: name), environment(covering: "Notification Center")),
                  case .reject = decide(RemoteAction(action: name), environment(frontmost: false)),
                  case .reject = decide(RemoteAction(action: name), environment(running: false)) else {
                return XCTFail("\(name) must be fenced")
            }
        }
    }

    func testReleaseIsAlwaysAllowed() {
        for name in ["release", "dragUp", "holdRenew"] {
            XCTAssertEqual(decide(RemoteAction(action: name), environment(frontmost: false, running: false)), .allow, name)
        }
    }

    func testOnlyAllowlistedKeys() {
        XCTAssertEqual(decide(RemoteAction(action: "key", key: "a", modifiers: ["command"]), environment()), .allow)
        XCTAssertEqual(decide(RemoteAction(action: "key", key: "v", modifiers: ["command"]), environment()), .allow)
        XCTAssertEqual(decide(RemoteAction(action: "key", key: "left", modifiers: ["shift"]), environment()), .allow)
        XCTAssertEqual(decide(RemoteAction(action: "key", key: "return"), environment()), .allow)
        for (key, modifiers) in [("q", ["command"]), ("tab", ["command"]), ("space", ["command"]), ("w", ["command"]),
                                 ("up", ["control"]), ("down", ["control"]), ("a", ["command", "option"])] {
            guard case .reject = decide(RemoteAction(action: "key", key: key, modifiers: modifiers), environment()) else {
                return XCTFail("\(modifiers)+\(key) must be refused")
            }
        }
        guard case .reject = decide(RemoteAction(action: "key", key: "a"), environment(frontmost: false)) else {
            return XCTFail("Typing needs the Test Pad frontmost")
        }
    }

    func testSpaceSwitchKeysNeedExplicitHarnessPermissionAwayFromTheTestPad() {
        let away = environment(frontmost: false)
        let left = RemoteAction(action: "key", key: "left", modifiers: ["control"])
        XCTAssertEqual(decide(left, environment()), .allow)
        guard case .reject = decide(left, away) else { return XCTFail("Space keys need the harness opt-in when away") }
        XCTAssertEqual(decide(left, away, spaceKeys: true), .allow)
        XCTAssertEqual(decide(RemoteAction(action: "key", key: "right", modifiers: ["control"]), away, spaceKeys: true), .allow)
    }

    // MARK: Coordinator auto-approval

    private func service() throws -> (Process, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        let bun = ["/opt/homebrew/bin/bun", NSHomeDirectory() + "/.bun/bin/bun", "/usr/local/bin/bun"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/bun"
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = [root.appendingPathComponent("scripts/test-service.ts").path]
        process.currentDirectoryURL = root
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let text = String(data: bytes, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw RemoteError.invalidMessage
        }
        return (process, "ws://127.0.0.1:\(port)/signal")
    }

    @MainActor
    private func waitFor(_ description: String, seconds: Double = 20, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    @MainActor
    func testHostApprovesOnlyAPhonePresentingTheToken() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let token = String(repeating: "7a", count: 32)
        var presented: [Data?] = []
        let host = RemoteCoordinator(isHost: true, store: E2EMemoryTrust())
        host.e2eProofApprover = { body in presented.append(body); return body == Data(token.utf8) }
        let intruder = RemoteCoordinator(isHost: false, store: E2EMemoryTrust())
        intruder.e2eEnrollmentProof = Data(String(repeating: "00", count: 32).utf8)
        defer { host.stop(); intruder.stop() }

        let invitation = try host.createPair(server: url, name: "E2E Mac")
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try intruder.enroll(invitation.code())
        try await waitFor("a wrong token falls back to human approval") { host.awaitingApproval }
        XCTAssertFalse(host.connected)
        XCTAssertEqual(presented.count, 1)
        intruder.stop()
        host.reject()

        let second = try host.createPair(server: url, name: "E2E Mac")
        host.start()
        try await waitFor("host registered again") { host.hostRegistered }
        let phone = RemoteCoordinator(isHost: false, store: E2EMemoryTrust())
        phone.e2eEnrollmentProof = Data(token.utf8)
        defer { phone.stop() }
        try phone.enroll(second.code())
        try await waitFor("token-bearing phone connected without human approval", seconds: 30) { host.connected && phone.connected }
        XCTAssertFalse(host.awaitingApproval)
        XCTAssertEqual(host.hostPair?.paired, true)
    }
}
