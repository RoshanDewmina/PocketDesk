import Foundation
import Network
import Darwin

/// A loopback-only listener that lets an AI coding agent's hook say "a person is needed" to Farside on
/// this Mac. It is the intake for agent alerts (SYSTEM-INTEGRATIONS.md section 5.1 and
/// PHONE-AND-AGENT-GAPS.md section 5.5), and it is built to be boring to attack:
///
/// - Bound to 127.0.0.1 on a random port. Nothing off this Mac can reach it.
/// - Every request needs the per-install bearer token, compared in constant time. The port and token
///   live in a 0600 file inside a 0700 directory that only this user can read.
/// - The Host header must name the listener and no browser headers may be present, so a web page cannot
///   reach it through DNS rebinding or cross-site requests.
/// - One request shape, parsed strictly and size-capped, with a read deadline and a connection cap.
/// - The body is read for an agent kind, a hashed session id and an event name. Any other field, such as
///   the agent's own message, is never read, stored or forwarded.
final class AgentAlertBridge: @unchecked Sendable {
    typealias Handler = @Sendable (AgentAlert) async -> AgentAlertDisposition

    /// What the hook script reads to find the bridge. `port` is 0 while the bridge is not listening.
    struct Discovery: Codable, Equatable {
        var version = 1
        var port: Int
        var token: String
        var pid: Int32
        var startedAt: Int
    }

    enum StartError: Error, Equatable {
        case listener(String)
        case storage(String)
    }

    static let fileName = "agent-bridge.json"
    static let maxConnections = 8
    static let defaultReadDeadline: TimeInterval = 3

    /// `~/Library/Application Support/Farside`
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Farside", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "com.roshan.PocketDesk.agent-bridge")
    private let directory: URL
    private let handler: Handler
    private let readDeadline: TimeInterval
    private var listener: NWListener?
    private var currentToken = ""
    private var currentPort: UInt16 = 0
    private var openConnections = 0

    init(directory: URL = AgentAlertBridge.defaultDirectory, readDeadline: TimeInterval = AgentAlertBridge.defaultReadDeadline,
         handler: @escaping Handler) {
        self.readDeadline = readDeadline
        self.directory = directory
        self.handler = handler
    }

    var discoveryFile: URL { directory.appendingPathComponent(Self.fileName) }
    var token: String { queue.sync { currentToken } }
    var port: UInt16 { queue.sync { currentPort } }

    // MARK: Lifecycle

    /// Starts listening and publishes the port and token. Returns the port.
    @discardableResult
    func start() async throws -> UInt16 {
        try prepareDirectory()
        let saved = Self.readDiscovery(at: discoveryFile)
        let token = saved.flatMap { Self.isToken($0.token) ? $0.token : nil } ?? Self.makeToken()

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw StartError.listener(error.localizedDescription) }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.take() { continuation.resume(throwing: StartError.listener(error.localizedDescription)) }
                case .cancelled:
                    if resumed.take() { continuation.resume(throwing: StartError.listener("cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        guard port != 0 else { listener.cancel(); throw StartError.listener("no port assigned") }

        queue.sync {
            self.listener?.cancel()
            self.listener = listener
            self.currentToken = token
            self.currentPort = port
        }
        do { try writeDiscovery(port: port) }
        catch {
            stop()
            throw StartError.storage(error.localizedDescription)
        }
        return port
    }

    /// Stops listening and marks the discovery file "not listening", keeping the token for next time.
    func stop() {
        let wasListening: Bool = queue.sync {
            let running = listener != nil
            listener?.cancel()
            listener = nil
            currentPort = 0
            return running
        }
        if wasListening { try? writeDiscovery(port: 0) }
    }

    /// A new token: every hook configured with the old one stops working until it reads the file again,
    /// which the script does on every call.
    @discardableResult
    func rotateToken() throws -> String {
        let fresh = Self.makeToken()
        let port = queue.sync { () -> UInt16 in
            currentToken = fresh
            return currentPort
        }
        try writeDiscovery(port: port)
        return fresh
    }

    // MARK: Storage

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw StartError.storage(error.localizedDescription)
        }
    }

    private func writeDiscovery(port: UInt16) throws {
        let value = Discovery(port: Int(port), token: token, pid: getpid(), startedAt: Int(Date().timeIntervalSince1970))
        let data = try JSONEncoder().encode(value)
        let temporary = directory.appendingPathComponent(".agent-bridge.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StartError.storage("The discovery file could not be created.")
        }
        if FileManager.default.fileExists(atPath: discoveryFile.path) {
            _ = try FileManager.default.replaceItemAt(discoveryFile, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: discoveryFile)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryFile.path)
    }

    static func readDiscovery(at file: URL) -> Discovery? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Discovery.self, from: $0) }
    }

    static func isToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func makeToken() -> String {
        (try? SecureRandom.token()) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard openConnections < Self.maxConnections else {
            connection.cancel()
            return
        }
        openConnections += 1
        let exchange = Exchange(connection: connection, bridge: self)
        connection.stateUpdateHandler = { [weak self, weak exchange] state in
            switch state {
            case .cancelled, .failed:
                self?.openConnections -= 1
                exchange?.abandon()
            default:
                break
            }
        }
        connection.start(queue: queue)
        exchange.receive()
        queue.asyncAfter(deadline: .now() + readDeadline) { [weak exchange] in exchange?.timeOut() }
    }

    /// Everything about one request, on the bridge's queue.
    private final class Exchange {
        private let connection: NWConnection
        private unowned let bridge: AgentAlertBridge
        private var buffer = Data()
        private var finished = false
        /// The request has been read and handed to the handler, so the read deadline no longer applies.
        private var handling = false

        init(connection: NWConnection, bridge: AgentAlertBridge) {
            self.connection = connection
            self.bridge = bridge
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
                guard !finished else { return }
                if let data { buffer.append(data) }
                switch AgentBridgeHTTP.parse(buffer) {
                case .needMore:
                    if isComplete || error != nil { finish(.badRequest) } else { receive() }
                case .reject(let status):
                    finish(status)
                case .request(let request):
                    route(request)
                }
            }
        }

        func timeOut() {
            guard !finished, !handling else { return }
            finish(.requestTimeout)
        }

        func abandon() { finished = true }

        private func finish(_ status: AgentBridgeHTTP.Status, json: String = "{}") {
            guard !finished else { return }
            finished = true
            connection.send(content: AgentBridgeHTTP.response(status, json: json), completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        private struct EventBody: Decodable {
            struct Agent: Decodable {
                var kind: String?
                var sessionHash: String?
            }
            var agent: Agent?
            var type: String
        }

        private func route(_ request: AgentBridgeHTTP.Request) {
            let port = bridge.currentPort
            if AgentBridgeGuard.looksLikeBrowser(request.headers) || !AgentBridgeGuard.hostIsLocal(request.headers["host"], port: port) {
                return finish(.forbidden, json: AgentBridgeHTTP.body("error", "forbidden"))
            }
            guard AgentBridgeGuard.isAuthorized(request.headers["authorization"], token: bridge.currentToken) else {
                return finish(.unauthorized, json: AgentBridgeHTTP.body("error", "unauthorized"))
            }
            switch (request.method, request.path) {
            case ("GET", "/agent/v1/health"):
                finish(.ok, json: "{\"ok\":true}")
            case ("POST", "/agent/v1/event"):
                event(request)
            case (_, "/agent/v1/health"), (_, "/agent/v1/event"):
                finish(.methodNotAllowed, json: AgentBridgeHTTP.body("error", "method_not_allowed"))
            default:
                finish(.notFound, json: AgentBridgeHTTP.body("error", "not_found"))
            }
        }

        private func event(_ request: AgentBridgeHTTP.Request) {
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                return finish(.unsupportedMediaType, json: AgentBridgeHTTP.body("error", "unsupported_media_type"))
            }
            guard let body = try? JSONDecoder().decode(EventBody.self, from: request.body),
                  AgentAlertFrame.isWord(body.type) else {
                return finish(.badRequest, json: AgentBridgeHTTP.body("error", "invalid_body"))
            }
            guard let event = AgentAlertEvent(rawValue: body.type) else {
                return finish(.ok, json: AgentBridgeHTTP.body("state", AgentAlertDisposition.ignored.rawValue))
            }
            let hash = body.agent?.sessionHash ?? "00000000"
            guard AgentAlert.isSessionHash(hash) else {
                return finish(.badRequest, json: AgentBridgeHTTP.body("error", "invalid_session"))
            }
            let alert = AgentAlert(id: AgentAlert.makeID(), kind: AgentKind(wire: body.agent?.kind), event: event,
                                   sessionHash: hash, raisedAt: Date())
            let handler = bridge.handler
            handling = true
            Task { [self] in
                let disposition = await handler(alert)
                bridge.queue.async { [self] in
                    finish(Self.status(for: disposition), json: AgentBridgeHTTP.body("state", disposition.rawValue))
                }
            }
        }

        private static func status(for disposition: AgentAlertDisposition) -> AgentBridgeHTTP.Status {
            switch disposition {
            case .forwarded, .pushed, .duplicate, .ignored: .ok
            case .noPhone, .pushUnavailable: .accepted
            case .rateLimited: .tooManyRequests
            case .disabled: .serviceUnavailable
            }
        }
    }
}

/// Lets a state handler resume a continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
