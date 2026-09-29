import XCTest
import CryptoKit

/// Shared plumbing for the Farside end-to-end UI tests. The iPhone simulator shares the Mac
/// filesystem, so these tests read the host, phone and Test Pad state straight from
/// /private/tmp/farside-e2e and ask script/e2e/run-e2e.sh for process-level actions through a
/// request/response directory. See script/e2e/README.md.
enum E2EPaths {
    static let root = "/private/tmp/farside-e2e"
    static var run: String { root + "/run" }
    static var config: String { run + "/config.json" }
    static var requests: String { run + "/requests" }
    static var responses: String { run + "/responses" }
    static var results: String { run + "/results" }
    static var token: String { root + "/secrets/pairing-token" }
    static var invitation: String { root + "/secrets/invitation.code" }
    static var hostState: String { root + "/host/state.json" }
    static var hostEvents: String { root + "/host/events.jsonl" }
    static var hostInput: String { root + "/host/input.jsonl" }
    static var phoneState: String { root + "/phone/state.json" }
    static var phoneEvents: String { root + "/phone/events.jsonl" }
    static var phoneCommands: String { root + "/phone/commands.jsonl" }
    static var padLog: String { root + "/testpad.jsonl" }
    static var padState: String { root + "/testpad-state.json" }
    static var padCommands: String { root + "/testpad-commands.jsonl" }
}

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func string(_ key: String) -> String? { self[key] as? String }
    func object(_ key: String) -> JSONObject { self[key] as? JSONObject ?? [:] }
    func point(_ key: String) -> CGPoint? {
        let value = object(key)
        guard let x = value.double("x"), let y = value.double("y") else { return nil }
        return CGPoint(x: x, y: y)
    }
    func rect(_ key: String) -> CGRect? {
        let value = object(key)
        guard let x = value.double("x"), let y = value.double("y"),
              let width = value.double("width"), let height = value.double("height") else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum E2EFile {
    static func json(_ path: String) -> JSONObject? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func text(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func append(_ object: JSONObject, to path: String) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw E2EFailure("cannot create \(path)")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { throw E2EFailure("cannot open \(path)") }
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func writeAtomically(_ object: JSONObject, to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let temporary = path + ".\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw E2EFailure("cannot write \(temporary)")
        }
        guard rename(temporary, path) == 0 else { throw E2EFailure("cannot move \(temporary)") }
    }

    static func age(_ path: String) -> TimeInterval? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }
}

/// Incremental JSON-lines reader: parses only bytes appended since the last read.
final class JSONLTail {
    let path: String
    private var offset: UInt64 = 0
    private var pending = Data()
    private(set) var lines: [JSONObject] = []

    init(path: String) { self.path = path }

    @discardableResult
    func refresh() -> [JSONObject] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return lines }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; pending = Data(); lines = [] }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return lines }
        offset += UInt64(data.count)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject { lines.append(object) }
        }
        return lines
    }

    /// Index to pass to `since` so only later lines are considered.
    func mark() -> Int { refresh().count }

    func since(_ mark: Int, type: String? = nil) -> [JSONObject] {
        let all = refresh()
        guard mark < all.count else { return [] }
        return Array(all[mark...]).filter { type == nil || $0.string("type") == type }
    }
}

/// Run parameters written by run-e2e.sh.
struct E2ERunConfig {
    let raw: JSONObject
    var runID: String { raw.string("runID") ?? "unknown" }
    var mode: String { raw.string("mode") ?? "real" }
    var isStub: Bool { mode == "stub" }
    var soakSeconds: Double { raw.double("soakSeconds") ?? 1200 }
    var backgroundShortSeconds: Double { raw.double("backgroundShortSeconds") ?? 5 }
    var backgroundLongSeconds: Double { raw.double("backgroundLongSeconds") ?? 60 }
    var spaceKeysEnabled: Bool { raw.bool("spaceKeysEnabled") }
    var reconnectTimeout: Double { raw.double("reconnectTimeoutSeconds") ?? 60 }

    static func load() throws -> E2ERunConfig {
        let path = ProcessInfo.processInfo.environment["FARSIDE_E2E_CONFIG"] ?? E2EPaths.config
        guard let raw = E2EFile.json(path) else {
            throw E2EFailure("No E2E run config at \(path). Start the suite with script/e2e/run-e2e.sh, not directly from Xcode.")
        }
        return E2ERunConfig(raw: raw)
    }
}

/// Asks run-e2e.sh to act on processes it owns (host, signaling service, Test Pad).
final class HarnessClient {
    private var counter = 0

    @discardableResult
    func request(_ action: String, _ parameters: JSONObject = [:], timeout: TimeInterval = 90) throws -> JSONObject {
        counter += 1
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))-\(counter)-\(action)"
        var body = parameters
        body["id"] = id
        body["action"] = action
        try E2EFile.writeAtomically(body, to: E2EPaths.requests + "/\(id).json")
        let deadline = Date().addingTimeInterval(timeout)
        let responsePath = E2EPaths.responses + "/\(id).json"
        while Date() < deadline {
            if let response = E2EFile.json(responsePath) {
                guard response.bool("ok") else {
                    throw E2EFailure("Harness action \(action) failed: \(response.string("message") ?? "no message")")
                }
                return response
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw E2EFailure("Harness did not answer \(action) within \(Int(timeout)) s. Is run-e2e.sh still running?")
    }
}

/// Farside Test Pad: events, geometry and setup commands.
final class TestPadClient {
    let log = JSONLTail(path: E2EPaths.padLog)
    private var counter = 0

    var state: JSONObject { E2EFile.json(E2EPaths.padState) ?? [:] }

    func element(_ name: String) -> CGRect? { state.object("elements").rect(name) }

    @discardableResult
    func command(_ name: String, _ parameters: JSONObject = [:], timeout: TimeInterval = 8) throws -> JSONObject {
        counter += 1
        let id = "xc-\(Int(Date().timeIntervalSince1970 * 1000))-\(counter)"
        let mark = log.mark()
        var body = parameters
        body["id"] = id
        body["cmd"] = name
        try E2EFile.append(body, to: E2EPaths.padCommands)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = log.since(mark, type: "command").first(where: { $0.string("id") == id }) {
                guard result.bool("ok") else { throw E2EFailure("Test Pad command \(name) failed: \(result.string("error") ?? "")") }
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw E2EFailure("Test Pad did not run \(name) within \(Int(timeout)) s. Is Farside Test Pad running?")
    }
}

/// Host state written by the host's E2E mode (real or stub).
final class HostClient {
    let events = JSONLTail(path: E2EPaths.hostEvents)
    let input = JSONLTail(path: E2EPaths.hostInput)

    var state: JSONObject { E2EFile.json(E2EPaths.hostState) ?? [:] }
    var stateAge: TimeInterval { E2EFile.age(E2EPaths.hostState) ?? .infinity }
    var pointer: CGPoint? { state.point("pointer") }
    var display: CGRect? { state.rect("display") }

    func summary() -> String {
        let s = state
        return "host[connected=\(s.bool("connected")) registered=\(s.bool("hostRegistered")) paired=\(s.bool("paired")) "
            + "capture=\(s.bool("captureHealthy")) control=\(s.bool("inputEnabled")) padFront=\(s.bool("testPadFrontmost")) "
            + "status=\(s.string("coordinatorStatus") ?? "?") fence=\(s.string("lastFenceRejection") ?? "-") age=\(String(format: "%.1f", stateAge))s]"
    }
}

/// Phone state from the app's E2E mode: file first, accessibility element as fallback.
final class PhoneClient {
    let app: XCUIApplication
    let events = JSONLTail(path: E2EPaths.phoneEvents)
    private var counter = 0

    init(app: XCUIApplication) { self.app = app }

    var state: JSONObject {
        if let file = E2EFile.json(E2EPaths.phoneState), let t = file.double("t"),
           Date().timeIntervalSince1970 - t < 2 { return file }
        let probe = app.descendants(matching: .any)["e2e.state"].firstMatch
        guard probe.exists, let value = probe.value as? String, let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return [:] }
        return object
    }

    var ready: Bool {
        let s = state
        return s.bool("connected") && s.bool("canControl") && s.bool("fresh") && s.bool("captureHealthy")
    }

    func summary() -> String {
        let s = state
        return "phone[connected=\(s.bool("connected")) canControl=\(s.bool("canControl")) fresh=\(s.bool("fresh")) "
            + "capture=\(s.bool("captureHealthy")) control=\(s.bool("controlAllowed")) epoch=\(s.int("geometryEpoch") ?? 0) "
            + "resume=\(s.string("resumeState") ?? "?") status=\(s.string("coordinatorStatus") ?? "?")]"
    }

    /// Sends a keyboard shortcut the phone UI has no button for through the admitted input path.
    func sendKey(_ key: String, modifiers: [String], timeout: TimeInterval = 5) throws {
        counter += 1
        let id = "xc-\(Int(Date().timeIntervalSince1970 * 1000))-\(counter)"
        let mark = events.mark()
        try E2EFile.append(["id": id, "cmd": "key", "key": key, "modifiers": modifiers], to: E2EPaths.phoneCommands)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = events.since(mark, type: "command").first(where: { $0.string("id") == id }) {
                guard result.bool("ok") else { throw E2EFailure("Phone could not send \(modifiers)+\(key); input was not admitted") }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw E2EFailure("Phone did not process the \(key) command within \(Int(timeout)) s")
    }
}

/// Per-scenario checks, metrics and result file.
final class ScenarioRecorder {
    let scenario: String
    let started = Date()
    private(set) var checks: [JSONObject] = []
    var metrics: JSONObject = [:]
    private(set) var notes: [String] = []

    init(scenario: String) { self.scenario = scenario }

    func note(_ text: String) {
        notes.append(text)
        print("E2E NOTE [\(scenario)] \(text)")
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "", value: Any? = nil,
               file: StaticString = #filePath, line: UInt = #line) {
        var entry: JSONObject = ["name": name, "ok": ok, "detail": detail,
                                 "at": Date().timeIntervalSince(started)]
        if let value { entry["value"] = value }
        checks.append(entry)
        print("E2E CHECK [\(scenario)] \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { XCTFail("\(name): \(detail)", file: file, line: line) }
    }

    func write(status: String, failure: String?) {
        var result: JSONObject = [
            "scenario": scenario, "status": status, "startedAt": started.timeIntervalSince1970,
            "durationSeconds": Date().timeIntervalSince(started), "checks": checks,
            "metrics": metrics, "notes": notes
        ]
        if let failure { result["failure"] = failure }
        try? FileManager.default.createDirectory(atPath: E2EPaths.results, withIntermediateDirectories: true)
        try? E2EFile.writeAtomically(result, to: E2EPaths.results + "/\(scenario).json")
    }
}

enum E2EDigest {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
