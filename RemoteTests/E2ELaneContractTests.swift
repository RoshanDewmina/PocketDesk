import XCTest
import Foundation
import Darwin

final class E2ELaneContractTests: XCTestCase {
    private var runRoot = ""
    private var environment: [String: String] = [:]
    private var manifest: [String: Any] = [:]
    private let now = Date().timeIntervalSince1970

    override func setUpWithError() throws {
        let run = "contract-" + UUID().uuidString
        for path in [E2E.root, E2E.root + "/parallel"] {
            if !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try E2ELaneContract.privateDirectory(path)
        }
        runRoot = E2E.root + "/parallel/" + run
        let root = runRoot + "/phone"
        try FileManager.default.createDirectory(atPath: runRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let udid = UUID().uuidString
        environment = ["FARSIDE_E2E": "1", "FARSIDE_E2E_DIR": root, "FARSIDE_E2E_RUN_ID": run,
                       "FARSIDE_E2E_LANE_MANIFEST": root + "/lane.json", "SIMULATOR_UDID": udid,
                       "FARSIDE_E2E_SIGNAL_URL": "ws://127.0.0.1:18790/signal"]
        manifest = ["schemaVersion": 1, "mode": "stub", "runID": run, "laneID": "phone", "root": root,
                    "ownerUID": getuid(), "leaseID": "lease-1", "udid": udid, "sessionID": "session-1",
                    "signalURL": environment["FARSIDE_E2E_SIGNAL_URL"]!, "createdAt": now, "expiresAt": now + 1800]
        try writeManifest()
    }

    override func tearDownWithError() throws {
        if !runRoot.isEmpty { try FileManager.default.removeItem(atPath: runRoot) }
    }

    private func writeManifest() throws {
        try E2EFiles.writePrivate(JSONSerialization.data(withJSONObject: manifest),
                                 to: environment[E2ELaneContract.manifestVariable]!)
    }

    private func validate(_ role: E2ELaneRole = .testRunner) throws -> E2ELaneManifest {
        try E2ELaneContract.validate(environment: environment, role: role, now: now)
    }

    func testValidLaneAndRealHostRefusal() throws {
        XCTAssertEqual(try validate().root, environment["FARSIDE_E2E_DIR"])
        XCTAssertNoThrow(try validate(.stubHost))
        XCTAssertThrowsError(try validate(.realHost))
        let options = E2ELaunchOptions(arguments: ["--farside-e2e"], environment: environment)
        XCTAssertThrowsError(try options.validatedCommon())
        XCTAssertNoThrow(try options.validatedCommon(role: .stubHost))
    }

    func testManifestIsARequestEvenWhenFlagsAreMissing() {
        for arguments in [[], ["--farside-e2e"]] {
            for flag in ["1", "0"] {
                var env = environment
                env["FARSIDE_E2E"] = flag
                let options = E2ELaunchOptions(arguments: arguments, environment: env)
                XCTAssertTrue(options.requested)
                if arguments.isEmpty || flag != "1" {
                    XCTAssertThrowsError(try options.validatedCommon(role: .stubHost))
                }
            }
        }
        var empty = environment; empty[E2ELaneContract.manifestVariable] = ""
        XCTAssertTrue(E2ELaunchOptions(arguments: [], environment: empty).requested)
        XCTAssertThrowsError(try E2ELaneContract.validate(environment: empty, role: .stubHost))
    }

    func testWrongMissingOSIdentityAndCrossLaneAreRejected() {
        for udid in [nil, UUID().uuidString] as [String?] {
            environment["SIMULATOR_UDID"] = udid
            XCTAssertThrowsError(try validate())
        }
        environment["FARSIDE_E2E_DIR"] = runRoot + "/tablet"
        XCTAssertThrowsError(try validate(.stubHost))
    }

    func testAliasesTraversalAndDuplicateSlashesAreRejected() {
        let root = environment["FARSIDE_E2E_DIR"]!
        for bad in [root.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"),
                    root + "/.", root + "/../phone", root.replacingOccurrences(of: "/parallel/", with: "/parallel//")] {
            environment["FARSIDE_E2E_DIR"] = bad
            environment[E2ELaneContract.manifestVariable] = bad + "/lane.json"
            XCTAssertThrowsError(try validate(.stubHost), bad)
        }
    }

    func testExpiryModeOwnerAndIdentityAreRejected() throws {
        let original = manifest
        let changes: [(String, Any)] = [("expiresAt", now - 1), ("createdAt", now + 60),
                                      ("mode", "real"), ("ownerUID", getuid() + 1),
                                      ("runID", "other"), ("root", "/private/tmp/other")]
        for (key, value) in changes {
            manifest = original; manifest[key] = value
            try writeManifest()
            XCTAssertThrowsError(try validate(.stubHost), key)
        }
    }

    func testSymlinkAndPublicManifestAreRejected() throws {
        let path = environment[E2ELaneContract.manifestVariable]!
        chmod(path, 0o644)
        XCTAssertThrowsError(try validate(.stubHost))
        chmod(path, 0o600)
        let real = runRoot + "/real.json"
        try FileManager.default.moveItem(atPath: path, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: real)
        XCTAssertThrowsError(try validate(.stubHost))
        try FileManager.default.removeItem(atPath: path)
        let root = environment["FARSIDE_E2E_DIR"]!
        let moved = runRoot + "/real-phone"
        try FileManager.default.moveItem(atPath: root, toPath: moved)
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: moved)
        XCTAssertThrowsError(try validate(.stubHost))
    }

    func testOneLanesProofCannotConsumeAnotherLanesToken() throws {
        let secret = runRoot + "/secrets"
        try FileManager.default.createDirectory(atPath: secret, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = secret + "/pairing-token"
        try E2EFiles.writePrivate(Data(String(repeating: "bb", count: 32).utf8), to: path)
        guard case .rejected = E2EPairingToken.consume(proof: Data(String(repeating: "aa", count: 32).utf8), secretsDirectory: secret) else {
            return XCTFail("cross-lane proof accepted")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
