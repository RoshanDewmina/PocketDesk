#if DEBUG
import Foundation
import Darwin

/// DEBUG stub-only lanes. This standalone file is also compiled into the UI test runner.
enum E2ELaneRole { case realHost, stubHost, simulatorPhone, testRunner }

struct E2ELaneError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct E2ELaneManifest: Codable {
    let schemaVersion: Int
    let mode: String
    let runID: String
    let laneID: String
    let root: String
    let ownerUID: UInt32
    let leaseID: String
    let udid: String
    let sessionID: String
    let signalURL: String
    let createdAt: Double
    let expiresAt: Double
}

enum E2ELaneContract {
    static let serialRoot = "/private/tmp/farside-e2e"
    static let manifestVariable = "FARSIDE_E2E_LANE_MANIFEST"

    static func requested(_ environment: [String: String]) -> Bool {
        environment[manifestVariable] != nil
    }

    static func identifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Reject aliases before reading; the private chain cannot contain symbolic links.
    static func privateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw E2ELaneError("lane directory must be an owned real 0700 directory: \(path)")
        }
    }

    static func validateChain(_ root: String) throws {
        let components = root.split(separator: "/", omittingEmptySubsequences: false)
        guard root.hasPrefix(serialRoot + "/parallel/"),
              components.first == "", components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw E2ELaneError("lane root must use the exact parallel-root spelling")
        }
        for systemPath in ["/private", "/private/tmp"] {
            var info = stat()
            guard lstat(systemPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw E2ELaneError("system temporary ancestry is not a real directory")
            }
        }
        let suffix = root.dropFirst(serialRoot.count).split(separator: "/")
        var current = serialRoot
        try privateDirectory(current)
        for component in suffix {
            current += "/" + component
            try privateDirectory(current)
        }
    }

    static func readPrivate(_ path: String, limit: Int = 16384) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw E2ELaneError("cannot open owned regular lane file: \(path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
              info.st_size > 0, info.st_size <= limit else {
            throw E2ELaneError("lane file must be owned, regular, 0600 and bounded: \(path)")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let length = bytes.count
        var offset = 0
        while offset < length {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), length - offset)
            }
            guard count > 0 else { throw E2ELaneError("lane file changed while reading") }
            offset += count
        }
        return Data(bytes)
    }

    static func validate(environment: [String: String], role: E2ELaneRole,
                         now: Double = Date().timeIntervalSince1970) throws -> E2ELaneManifest {
        guard role != .realHost else { throw E2ELaneError("real hosts cannot use a parallel lane manifest") }
        guard environment["FARSIDE_E2E"] == "1",
              let path = environment[manifestVariable],
              let root = environment["FARSIDE_E2E_DIR"],
              let runID = environment["FARSIDE_E2E_RUN_ID"], identifier(runID) else {
            throw E2ELaneError("incomplete lane environment")
        }
        let parts = root.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[1...4].joined(separator: "/") == "private/tmp/farside-e2e/parallel",
              parts[5] == runID, identifier(String(parts[6])), path == root + "/lane.json" else {
            throw E2ELaneError("lane manifest must use its exact run/lane path")
        }
        try validateChain(root)
        let manifest = try JSONDecoder().decode(E2ELaneManifest.self, from: readPrivate(path))
        guard manifest.schemaVersion == 1, manifest.mode == "stub", manifest.root == root,
              manifest.runID == runID, manifest.laneID == String(parts[6]), manifest.ownerUID == getuid(),
              identifier(manifest.leaseID), identifier(manifest.sessionID), UUID(uuidString: manifest.udid) != nil,
              manifest.createdAt.isFinite, manifest.expiresAt.isFinite,
              manifest.createdAt <= now + 5, manifest.expiresAt > now,
              manifest.expiresAt > manifest.createdAt, manifest.expiresAt - manifest.createdAt <= 3600,
              manifest.signalURL == environment["FARSIDE_E2E_SIGNAL_URL"],
              let url = URLComponents(string: manifest.signalURL), url.scheme == "ws",
              url.host == "127.0.0.1", let port = url.port, (18790...18899).contains(port),
              url.path == "/signal", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw E2ELaneError("lane manifest identity, TTL or signaling policy mismatch")
        }
        if role == .simulatorPhone || role == .testRunner {
            guard let actual = environment["SIMULATOR_UDID"], actual.lowercased() == manifest.udid.lowercased() else {
                throw E2ELaneError("OS-provided SIMULATOR_UDID is missing or differs from the lane")
            }
        }
        return manifest
    }
}
#endif
