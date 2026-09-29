import Foundation

enum SessionActivityPushEnvironment: String, Codable, Sendable {
    case sandbox, production

    static func configured(bundle: Bundle = .main) -> Self? {
        configured(value: bundle.object(forInfoDictionaryKey: "FarsideAPNSEnvironment") as? String)
    }

    static func configured(value: String?) -> Self? {
        switch value {
        case "development": .sandbox
        case "production": .production
        default: nil
        }
    }
}

/// Authenticated context for exactly one current pairing and route. It is intentionally neither
/// printable nor logged: `token` is the pairing proof used by the existing backend protocol.
struct SessionActivityPushPairing: Equatable, Sendable {
    let server: String
    let room: String
    let token: String
    let routeEpoch: String
    let pairingID: String
    let environment: SessionActivityPushEnvironment

    init?(server: String, room: String, token: String, routeEpoch: String,
          pairingID: String, environment: SessionActivityPushEnvironment) {
        guard SessionActivityPushEndpoint.origin(for: server) != nil,
              SecureRandom.isToken(room), SecureRandom.isToken(token),
              Self.isEpoch(routeEpoch), !pairingID.isEmpty else { return nil }
        self.server = server
        self.room = room
        self.token = token
        self.routeEpoch = routeEpoch
        self.pairingID = pairingID
        self.environment = environment
    }

    private static func isEpoch(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct SessionActivityPushScope: Equatable, Sendable {
    let pairing: SessionActivityPushPairing
    let activityID: String
    let sessionID: String
    let generation: UUID
}

struct SessionActivityPushRequest: Equatable, Sendable {
    let scope: SessionActivityPushScope
    let pushToken: String

    init?(scope: SessionActivityPushScope, token: Data) {
        // Apple explicitly says APNs device tokens are variable length. Do not assume 32 bytes:
        // https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/HandlingRemoteNotifications.html
        guard !token.isEmpty, token.count <= 512 else { return nil }
        self.scope = scope
        self.pushToken = token.map { String(format: "%02x", $0) }.joined()
    }
}

protocol SessionActivityPushSink: Sendable {
    var isConfigured: Bool { get }
    func register(_ request: SessionActivityPushRequest) async throws
    func remove(_ request: SessionActivityPushRequest) async throws
}

struct UnavailableSessionActivityPushSink: SessionActivityPushSink {
    let isConfigured = false
    func register(_ request: SessionActivityPushRequest) async throws {}
    func remove(_ request: SessionActivityPushRequest) async throws {}
}

enum SessionActivityPushServiceError: Error, Equatable {
    case invalidOrigin, encoding, unreachable, invalidResponse, refused(status: Int)
}

enum SessionActivityPushEndpoint {
    static func origin(for signalingServer: String) -> URL? {
        guard let source = URLComponents(string: signalingServer), source.scheme == "wss",
              let host = source.host, !host.isEmpty, source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil, source.path == "/signal" else { return nil }
        var target = URLComponents()
        target.scheme = "https"
        target.host = host
        target.port = source.port
        target.path = ""
        return target.url
    }

    static func url(for path: String, signalingServer: String) -> URL? {
        origin(for: signalingServer)?.appending(path: path)
    }

    static func isSameOrigin(_ candidate: URL, as origin: URL) -> Bool {
        candidate.scheme == "https" && origin.scheme == "https"
            && candidate.host?.lowercased() == origin.host?.lowercased()
            && (candidate.port ?? 443) == (origin.port ?? 443)
    }
}

struct SessionActivityPushBody: Encodable {
    let room: String
    let token: String
    let routeEpoch: String
    let activityId: String
    let pushToken: String
    let environment: SessionActivityPushEnvironment

    init(_ request: SessionActivityPushRequest) {
        room = request.scope.pairing.room
        token = request.scope.pairing.token
        routeEpoch = request.scope.pairing.routeEpoch
        activityId = request.scope.activityID
        pushToken = request.pushToken
        environment = request.scope.pairing.environment
    }
}

final class SessionActivityNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HTTPSessionActivityPushSink: SessionActivityPushSink {
    let isConfigured = true
    private let session: URLSession
    private let timeout: TimeInterval

    init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 10) {
        self.timeout = timeout
        session = URLSession(configuration: configuration,
                             delegate: SessionActivityNoRedirectDelegate(), delegateQueue: nil)
    }

    func register(_ request: SessionActivityPushRequest) async throws {
        try await post(request, path: "/v1/activity/register", expectedStatus: 200)
    }

    func remove(_ request: SessionActivityPushRequest) async throws {
        try await post(request, path: "/v1/activity/remove", expectedStatus: 204)
    }

    private func post(_ request: SessionActivityPushRequest, path: String, expectedStatus: Int) async throws {
        guard let endpoint = SessionActivityPushEndpoint.url(for: path,
                                                              signalingServer: request.scope.pairing.server),
              let expectedOrigin = SessionActivityPushEndpoint.origin(for: request.scope.pairing.server) else {
            throw SessionActivityPushServiceError.invalidOrigin
        }
        var http = URLRequest(url: endpoint, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        do { http.httpBody = try JSONEncoder().encode(SessionActivityPushBody(request)) }
        catch { throw SessionActivityPushServiceError.encoding }
        let response: URLResponse
        do { (_, response) = try await session.data(for: http) }
        catch { throw SessionActivityPushServiceError.unreachable }
        guard let httpResponse = response as? HTTPURLResponse,
              let responseURL = httpResponse.url,
              SessionActivityPushEndpoint.isSameOrigin(responseURL, as: expectedOrigin)
        else { throw SessionActivityPushServiceError.invalidResponse }
        guard httpResponse.statusCode == expectedStatus else {
            throw SessionActivityPushServiceError.refused(status: httpResponse.statusCode)
        }
    }
}

/// Serializes token rotation and cleanup. Every request carries the activity generation and exact
/// token tuple; a completion from an old task can remove only the registration it created.
actor SessionActivityPushLifecycle {
    private struct Pending: Sendable {
        let request: SessionActivityPushRequest
        let revision: UInt64
    }

    private let sink: any SessionActivityPushSink
    private let retryDelay: @Sendable (Int) async -> Void
    private var scope: SessionActivityPushScope?
    private var current: SessionActivityPushRequest?
    /// Owned by this lifecycle rather than the Activity observer task. Canceling an old observer
    /// therefore cannot cancel registration for a replacement scope.
    private var drainTask: Task<Void, Never>?
    private var pending: Pending?
    private var revision: UInt64 = 0
    private var cleanupTail: Task<Void, Never>?
    init(sink: any SessionActivityPushSink,
         retryDelay: @escaping @Sendable (Int) async -> Void = { attempt in
             try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
         }) {
        self.sink = sink
        self.retryDelay = retryDelay
    }

    var isConfigured: Bool { sink.isConfigured }

    func begin(pairing: SessionActivityPushPairing, activityID: String,
               sessionID: String) -> SessionActivityPushScope {
        revision &+= 1
        pending = nil
        let old = current
        current = nil
        let next = SessionActivityPushScope(pairing: pairing, activityID: activityID,
                                            sessionID: sessionID, generation: UUID())
        scope = next
        if let old { scheduleRemove(old) }
        return next
    }

    func receive(token: Data, for candidate: SessionActivityPushScope) {
        guard candidate == scope, let request = SessionActivityPushRequest(scope: candidate, token: token),
              request != current else { return }
        revision &+= 1
        pending = Pending(request: request, revision: revision)
        if drainTask == nil {
            drainTask = Task.detached { [self] in await drain() }
        }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            await register(next.request, revision: next.revision)
        }
        drainTask = nil
    }

    private func register(_ request: SessionActivityPushRequest, revision mine: UInt64) async {
        guard request.scope == scope, request != current, mine == revision else { return }
        // Finish every older conditional remove before writing a replacement. This also protects a
        // rare A -> B -> A token sequence: an old remove(A) can never run after the new register(A).
        // The backend may still reject reused A because its explicit-remove tombstone is terminal;
        // serialization prevents a race, but does not promise that a removed tuple can be revived.
        let priorCleanup = cleanupTail
        await priorCleanup?.value
        guard request.scope == scope, mine == revision else { return }
        var registered = false
        var ambiguous = false
        for attempt in 0..<3 {
            do {
                try await sink.register(request)
                registered = true
                break
            } catch {
                guard request.scope == scope, mine == revision else {
                    scheduleRemove(request)
                    return
                }
                guard Self.isAmbiguousRegistrationFailure(error) else {
                    if ambiguous { break }
                    return
                }
                ambiguous = true
                if attempt < 2 {
                    await retryDelay(attempt)
                    guard request.scope == scope, mine == revision else {
                        scheduleRemove(request)
                        return
                    }
                }
            }
        }
        guard request.scope == scope, mine == revision else {
            scheduleRemove(request)
            return
        }
        let old = current
        // An exhausted transport failure may mean the service stored the tuple and only its reply
        // was lost. Keep that exact tuple as current so End/supersession cleans it later; removing it
        // while live would create the backend's terminal tombstone and prevent a valid retry.
        guard registered || ambiguous else { return }
        current = request
        if let old, old != request { scheduleRemove(old) }
    }

    private static func isAmbiguousRegistrationFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? SessionActivityPushServiceError else { return true }
        switch serviceError {
        case .invalidOrigin, .encoding: return false
        case .refused(let status): return status == 408 || status == 429 || status >= 500
        case .unreachable, .invalidResponse: return true
        }
    }

    func finish(_ candidate: SessionActivityPushScope) {
        guard candidate == scope else { return }
        revision &+= 1
        scope = nil
        pending = nil
        let old = current
        current = nil
        if let old { scheduleRemove(old) }
    }

    /// Cleanup is serialized separately from registration and never blocks a local ActivityKit
    /// command. The backend's exact-tuple conditional remove makes overlap with a replacement safe.
    private func scheduleRemove(_ request: SessionActivityPushRequest) {
        let previous = cleanupTail
        let sink = self.sink
        let retryDelay = self.retryDelay
        cleanupTail = Task {
            await previous?.value
            for attempt in 0..<3 {
                do { try await sink.remove(request); return }
                catch { if attempt < 2 { await retryDelay(attempt) } }
            }
        }
    }

    /// A deterministic test boundary. Production local commands never call this.
    func settleTransport() async {
        await drainTask?.value
        await cleanupTail?.value
    }
}
