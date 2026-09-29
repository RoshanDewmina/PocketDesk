import Foundation
import XCTest
@testable import PocketDeskRemote

final class SessionActivityPushTests: XCTestCase {
    private func pairing(server: String = "wss://relay.example/signal",
                         epoch: String = String(repeating: "a", count: 32),
                         environment: SessionActivityPushEnvironment = .sandbox) -> SessionActivityPushPairing {
        SessionActivityPushPairing(server: server,
                                   room: String(repeating: "b", count: 64),
                                   token: String(repeating: "c", count: 64),
                                   routeEpoch: epoch,
                                   pairingID: "m_test",
                                   environment: environment)!
    }

    func testAPNsEnvironmentMustBeExplicitlyKnown() {
        XCTAssertEqual(SessionActivityPushEnvironment.configured(value: "development"), .sandbox)
        XCTAssertEqual(SessionActivityPushEnvironment.configured(value: "production"), .production)
        XCTAssertNil(SessionActivityPushEnvironment.configured(value: nil))
        XCTAssertNil(SessionActivityPushEnvironment.configured(value: "staging"))
    }

    private func scope(pairing: SessionActivityPushPairing? = nil,
                       activityID: String = "activity-opaque") -> SessionActivityPushScope {
        SessionActivityPushScope(pairing: pairing ?? self.pairing(), activityID: activityID,
                                 sessionID: "session", generation: UUID())
    }

    func testPairingRequiresExactAuthenticatedWSSRouteContext() {
        XCTAssertNotNil(SessionActivityPushPairing(
            server: "wss://relay.example:8443/signal",
            room: String(repeating: "1", count: 64), token: String(repeating: "2", count: 64),
            routeEpoch: String(repeating: "a", count: 32), pairingID: "m_test", environment: .production))
        for server in ["ws://relay.example/signal", "wss://user@relay.example/signal",
                       "wss://relay.example/other", "wss://relay.example/signal?q=1"] {
            XCTAssertNil(SessionActivityPushPairing(
                server: server, room: String(repeating: "1", count: 64),
                token: String(repeating: "2", count: 64),
                routeEpoch: String(repeating: "a", count: 32), pairingID: "m_test", environment: .sandbox))
        }
        XCTAssertNil(SessionActivityPushPairing(
            server: "wss://relay.example/signal", room: String(repeating: "1", count: 64),
            token: String(repeating: "2", count: 64), routeEpoch: String(repeating: "A", count: 32),
            pairingID: "m_test", environment: .sandbox))
    }

    func testPushTokenIsVariableLengthLowercaseHexWithPayloadBound() {
        XCTAssertEqual(SessionActivityPushRequest(scope: scope(), token: Data([0, 1, 0xab, 0xff]))?.pushToken,
                       "0001abff")
        XCTAssertNotNil(SessionActivityPushRequest(scope: scope(), token: Data(repeating: 7, count: 80)),
                        "Apple documents APNs tokens as variable length")
        XCTAssertNil(SessionActivityPushRequest(scope: scope(), token: Data()))
        XCTAssertNil(SessionActivityPushRequest(scope: scope(), token: Data(repeating: 0, count: 513)))
    }

    func testEndpointDerivesOnlyHTTPSOnThePairedOrigin() {
        XCTAssertEqual(SessionActivityPushEndpoint.url(for: "/v1/activity/register",
                                                        signalingServer: "wss://relay.example:8443/signal")?.absoluteString,
                       "https://relay.example:8443/v1/activity/register")
        let origin = URL(string: "https://relay.example")!
        XCTAssertTrue(SessionActivityPushEndpoint.isSameOrigin(URL(string: "https://RELAY.example/path")!, as: origin))
        XCTAssertFalse(SessionActivityPushEndpoint.isSameOrigin(URL(string: "https://relay.example:444/path")!, as: origin))
        XCTAssertFalse(SessionActivityPushEndpoint.isSameOrigin(URL(string: "http://relay.example/path")!, as: origin))
    }

    func testHTTPContractUsesExactPathsStatusesAndFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityPushURLProtocol.self]
        let sink = HTTPSessionActivityPushSink(configuration: configuration, timeout: 1)
        let request = SessionActivityPushRequest(scope: scope(), token: Data([0xde, 0xad]))!
        ActivityPushURLProtocol.handler = { request in
            let body = try XCTUnwrap(ActivityPushURLProtocol.body(of: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(Set(json.keys), ["room", "token", "routeEpoch", "activityId", "pushToken", "environment"])
            XCTAssertEqual(json["activityId"], "activity-opaque")
            XCTAssertEqual(json["pushToken"], "dead")
            XCTAssertEqual(json["environment"], "sandbox")
            XCTAssertEqual(request.httpMethod, "POST")
            switch request.url?.path {
            case "/v1/activity/register": return 200
            case "/v1/activity/remove": return 204
            default: return 404
            }
        }
        defer { ActivityPushURLProtocol.handler = nil }

        try await sink.register(request)
        try await sink.remove(request)
    }

    func testHTTPContractRejectsNearMissSuccessStatuses() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityPushURLProtocol.self]
        let sink = HTTPSessionActivityPushSink(configuration: configuration, timeout: 1)
        let request = SessionActivityPushRequest(scope: scope(), token: Data([1]))!
        ActivityPushURLProtocol.handler = { request in
            request.url?.path == "/v1/activity/register" ? 201 : 200
        }
        defer { ActivityPushURLProtocol.handler = nil }

        do {
            try await sink.register(request)
            XCTFail("Register must require HTTP 200")
        } catch {
            XCTAssertEqual(error as? SessionActivityPushServiceError, .refused(status: 201))
        }
        do {
            try await sink.remove(request)
            XCTFail("Remove must require HTTP 204")
        } catch {
            XCTAssertEqual(error as? SessionActivityPushServiceError, .refused(status: 200))
        }

        let rejecting = RegistryPushSink(refusedStatus: 400)
        let lifecycle = SessionActivityPushLifecycle(sink: rejecting, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "rejected", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await lifecycle.settleTransport()
        let rejected = await rejecting.state()
        XCTAssertEqual(rejected.registered.count, 1, "A definitive HTTP 4xx is not retried")
        XCTAssertTrue(rejected.registry.isEmpty)
        XCTAssertTrue(rejected.removeAttempts.isEmpty, "A rejected tuple must not be tombstoned")
    }

    func testHTTPClientNeverFollowsARedirect() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityPushURLProtocol.self]
        let sink = HTTPSessionActivityPushSink(configuration: configuration, timeout: 1)
        let request = SessionActivityPushRequest(scope: scope(), token: Data([1]))!
        ActivityPushURLProtocol.seenURLs = []
        ActivityPushURLProtocol.redirectTarget = URL(string: "https://attacker.example/collect")!
        defer {
            ActivityPushURLProtocol.redirectTarget = nil
            ActivityPushURLProtocol.seenURLs = []
        }

        do {
            try await sink.register(request)
            XCTFail("A redirect is never an accepted registration")
        } catch {}
        XCTAssertEqual(ActivityPushURLProtocol.seenURLs.compactMap(\.host), ["relay.example"])
    }

    @MainActor
    func testRemoteEndIsFailClosedAndNeverEnabledForPreview() {
        let real = FarsideSessionAttributes(macId: "m_test", macLabel: "Mac", sessionId: "s",
                                            startedAtUnix: 1, preview: nil)
        let preview = FarsideSessionAttributes(macId: "m_preview", macLabel: "Mac", sessionId: "preview",
                                               startedAtUnix: 1, preview: true)
        XCTAssertFalse(ActivityKitSessionClient.allowsRemoteEnd(attributes: real, sinkConfigured: false,
                                                                 pairing: pairing()))
        XCTAssertFalse(ActivityKitSessionClient.allowsRemoteEnd(attributes: real, sinkConfigured: true,
                                                                 pairing: nil))
        XCTAssertFalse(ActivityKitSessionClient.allowsRemoteEnd(attributes: preview, sinkConfigured: true,
                                                                 pairing: pairing()))
        XCTAssertTrue(ActivityKitSessionClient.allowsRemoteEnd(attributes: real, sinkConfigured: true,
                                                                pairing: pairing()))
    }

    func testRotationRegistersNewTokenBeforeConditionallyRemovingOldTuple() async {
        let sink = RegistryPushSink()
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await lifecycle.settleTransport()
        await lifecycle.receive(token: Data([2]), for: scope)
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertEqual(state.registry["activity"], "02")
        XCTAssertEqual(state.registered.map(\.pushToken), ["01", "02"])
        XCTAssertEqual(state.removed.map(\.pushToken), ["01"])
    }

    func testOverlappingTokenCallbacksCannotLeaveTheServerOnAnOlderToken() async {
        let held = expectation(description: "old registration reached transport")
        let sink = RegistryPushSink(heldToken: "01", onHeld: { held.fulfill() })
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        let first = Task { await lifecycle.receive(token: Data([1]), for: scope) }
        await fulfillment(of: [held], timeout: 2)
        await lifecycle.receive(token: Data([2]), for: scope)
        let blocked = await sink.state()
        XCTAssertEqual(blocked.registered.map(\.pushToken), ["01"],
                       "A second register must not overtake the first network request")

        await sink.releaseHeldRegister()
        await first.value
        await lifecycle.settleTransport()
        let state = await sink.state()
        XCTAssertEqual(state.registry["activity"], "02")
        XCTAssertEqual(state.registered.map(\.pushToken), ["01", "02"])
        XCTAssertEqual(state.removed.map(\.pushToken), ["01"])
    }

    func testStaleFinishCannotDeleteReplacementActivityRegistration() async {
        let sink = RegistryPushSink()
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let old = await lifecycle.begin(pairing: pairing(), activityID: "old", sessionID: "one")
        await lifecycle.receive(token: Data([1]), for: old)
        await lifecycle.settleTransport()
        let new = await lifecycle.begin(pairing: pairing(), activityID: "new", sessionID: "two")
        await lifecycle.receive(token: Data([2]), for: new)
        await lifecycle.finish(old)
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["old"])
        XCTAssertEqual(state.registry["new"], "02")
        XCTAssertFalse(state.removed.contains { $0.scope.activityID == "new" })
    }

    func testNewActivityWaitsOutAndCleansAnOldInflightRegistration() async {
        let held = expectation(description: "old registration reached transport")
        let sink = RegistryPushSink(heldToken: "01", onHeld: { held.fulfill() })
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let old = await lifecycle.begin(pairing: pairing(), activityID: "old", sessionID: "one")
        let oldRegistration = Task { await lifecycle.receive(token: Data([1]), for: old) }
        await fulfillment(of: [held], timeout: 2)

        let new = await lifecycle.begin(pairing: pairing(), activityID: "new", sessionID: "two")
        await lifecycle.receive(token: Data([2]), for: new)
        await lifecycle.finish(old)
        await sink.releaseHeldRegister()
        await oldRegistration.value
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["old"])
        XCTAssertEqual(state.registry["new"], "02")
        XCTAssertEqual(state.registered.map { "\($0.scope.activityID):\($0.pushToken)" },
                       ["old:01", "new:02"])
    }

    func testRemovalRetriesAreBoundedAndUseTheSameTuple() async {
        let sink = RegistryPushSink(removeFailures: 2)
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await lifecycle.settleTransport()
        await lifecycle.finish(scope)
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["activity"])
        XCTAssertEqual(state.removeAttempts.map(\.pushToken), ["01", "01", "01"])
    }

    func testLostFirstRegisterResponseRetriesWithoutRemovingTheLiveTuple() async {
        let sink = RegistryPushSink(registerFailuresAfterWrite: 1)
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertEqual(state.registry["activity"], "01")
        XCTAssertEqual(state.registered.map(\.pushToken), ["01", "01"])
        XCTAssertTrue(state.removeAttempts.isEmpty,
                      "A lost response must never tombstone a tuple while its activity is live")
    }

    func testExhaustedAmbiguousRegisterRemainsUntilFinishCleanup() async {
        let sink = RegistryPushSink(registerFailuresAfterWrite: 3,
                                    registerFailureIsCancellation: true)
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await lifecycle.settleTransport()

        var state = await sink.state()
        XCTAssertEqual(state.registry["activity"], "01")
        XCTAssertEqual(state.registered.count, 3)
        XCTAssertTrue(state.removeAttempts.isEmpty)

        await lifecycle.finish(scope)
        await lifecycle.settleTransport()
        state = await sink.state()
        XCTAssertNil(state.registry["activity"])
        XCTAssertEqual(state.removed.map(\.pushToken), ["01"])
    }

    func testFinishDuringRegisterBackoffCleansWithoutRetryingTheEndedScope() async {
        let backoff = expectation(description: "registration entered retry backoff")
        let gate = RegistrationRetryGate(onWait: { backoff.fulfill() })
        let sink = RegistryPushSink(registerFailuresAfterWrite: 1)
        let lifecycle = SessionActivityPushLifecycle(
            sink: sink, retryDelay: { attempt in await gate.wait(attempt: attempt) })
        let scope = await lifecycle.begin(pairing: pairing(), activityID: "activity", sessionID: "session")
        await lifecycle.receive(token: Data([1]), for: scope)
        await fulfillment(of: [backoff], timeout: 2)

        await lifecycle.finish(scope)
        await gate.releaseAll()
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["activity"])
        XCTAssertEqual(state.registered.map(\.pushToken), ["01"])
        XCTAssertEqual(state.removed.map(\.pushToken), ["01"])
    }

    func testSupersessionDuringRegisterBackoffCleansOldBeforeRegisteringNew() async {
        let backoff = expectation(description: "old registration entered retry backoff")
        let gate = RegistrationRetryGate(onWait: { backoff.fulfill() })
        let sink = RegistryPushSink(registerFailuresAfterWrite: 1)
        let lifecycle = SessionActivityPushLifecycle(
            sink: sink, retryDelay: { attempt in await gate.wait(attempt: attempt) })
        let old = await lifecycle.begin(pairing: pairing(), activityID: "old", sessionID: "one")
        await lifecycle.receive(token: Data([1]), for: old)
        await fulfillment(of: [backoff], timeout: 2)

        let new = await lifecycle.begin(pairing: pairing(), activityID: "new", sessionID: "two")
        await lifecycle.receive(token: Data([2]), for: new)
        await gate.releaseAll()
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["old"])
        XCTAssertEqual(state.registry["new"], "02")
        XCTAssertEqual(state.registered.map { "\($0.scope.activityID):\($0.pushToken)" },
                       ["old:01", "new:02"])
        XCTAssertEqual(state.removed.map(\.scope.activityID), ["old"])
    }

    @MainActor
    func testControllerEndCompletesWhileRegistrationTransportIsStillHeld() async {
        let held = expectation(description: "controller registration reached transport")
        let sink = RegistryPushSink(heldToken: "01", onHeld: { held.fulfill() })
        let client = ControllerBoundaryPushClient(sink: sink)
        let controller = SessionActivityController(client: client)
        controller.identity = { ("m_test", "Mac") }
        controller.pushPairing = { self.pairing() }
        controller.keepAliveInterval = nil

        controller.apply(SessionSnapshot(connected: true))
        await controller.settle()
        await fulfillment(of: [held], timeout: 2)

        controller.apply(SessionSnapshot(connected: false, endReason: .user))
        await fulfillment(of: [client.localEndExpectation], timeout: 0.5)
        XCTAssertTrue(client.localEndCompleted,
                      "Local End must not wait for the held registration or its cleanup retries")
        let heldState = await sink.state()
        XCTAssertEqual(heldState.registered.map(\.pushToken), ["01"])

        await sink.releaseHeldRegister()
        await controller.settle()
        await client.settleTransport()
        let state = await sink.state()
        XCTAssertNil(state.registry["controller-activity"])
        XCTAssertEqual(state.removed.map(\.pushToken), ["01"])
    }

    func testCancelledOldObserverCannotCancelReplacementScopeRegistration() async {
        let held = expectation(description: "old observer registration reached transport")
        let sink = RegistryPushSink(heldToken: "01", rejectCancelledRegistrations: true,
                                    onHeld: { held.fulfill() })
        let lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
        let old = await lifecycle.begin(pairing: pairing(), activityID: "old", sessionID: "one")
        let oldObserver = Task {
            await lifecycle.receive(token: Data([1]), for: old)
            while !Task.isCancelled { await Task.yield() }
        }
        await fulfillment(of: [held], timeout: 2)

        oldObserver.cancel()
        await oldObserver.value
        await lifecycle.finish(old)
        let new = await lifecycle.begin(pairing: pairing(), activityID: "new", sessionID: "two")
        await lifecycle.receive(token: Data([2]), for: new)
        await sink.releaseHeldRegister()
        await lifecycle.settleTransport()

        let state = await sink.state()
        XCTAssertNil(state.registry["old"])
        XCTAssertEqual(state.registry["new"], "02",
                       "The lifecycle-owned drain must not inherit cancellation from the old observer")
        XCTAssertEqual(state.registered.map { "\($0.scope.activityID):\($0.pushToken)" },
                       ["old:01", "new:02"])
    }
}

@MainActor
private final class ControllerBoundaryPushClient: SessionActivityClient {
    let isEnabled = true
    private let lifecycle: SessionActivityPushLifecycle
    private var pairing: SessionActivityPushPairing?
    private var scope: SessionActivityPushScope?
    private var registration: Task<Void, Never>?
    let localEndExpectation = XCTestExpectation(description: "local Activity end")
    private(set) var localEndCompleted = false

    init(sink: any SessionActivityPushSink) {
        lifecycle = SessionActivityPushLifecycle(sink: sink, retryDelay: { _ in })
    }

    func setPushPairing(_ pairing: SessionActivityPushPairing?) { self.pairing = pairing }

    func start(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
               staleDate: Date?) async -> Bool {
        guard let pairing else { return false }
        let scope = await lifecycle.begin(pairing: pairing, activityID: "controller-activity",
                                          sessionID: attributes.sessionId)
        self.scope = scope
        registration = Task { [lifecycle] in
            await lifecycle.receive(token: Data([1]), for: scope)
        }
        return true
    }

    func update(state: FarsideSessionAttributes.ContentState, staleDate: Date?) async {}

    func end(reason: FarsideSessionAttributes.EndReason) async {
        if let scope { self.scope = nil; await lifecycle.finish(scope) }
        localEndCompleted = true
        localEndExpectation.fulfill()
    }

    func endStrays() async {}

    func settleTransport() async {
        await registration?.value
        await lifecycle.settleTransport()
    }
}

private final class ActivityPushURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Int)?
    nonisolated(unsafe) static var redirectTarget: URL?
    nonisolated(unsafe) static var seenURLs: [URL] = []

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            if let url = request.url { Self.seenURLs.append(url) }
            if let target = Self.redirectTarget {
                var redirected = URLRequest(url: target)
                redirected.httpMethod = request.httpMethod
                redirected.httpBody = Self.body(of: request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                return
            }
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let status = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private actor RegistrationRetryGate {
    private let onWait: @Sendable () -> Void
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(onWait: @escaping @Sendable () -> Void) { self.onWait = onWait }

    func wait(attempt: Int) async {
        onWait()
        await withCheckedContinuation { continuations.append($0) }
    }

    func releaseAll() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor RegistryPushSink: SessionActivityPushSink {
    struct State: Sendable {
        var registry: [String: String]
        var registered: [SessionActivityPushRequest]
        var removed: [SessionActivityPushRequest]
        var removeAttempts: [SessionActivityPushRequest]
    }

    nonisolated let isConfigured = true
    private let heldToken: String?
    private var registerFailuresAfterWrite: Int
    private let registerFailureIsCancellation: Bool
    private let refusedStatus: Int?
    private let rejectCancelledRegistrations: Bool
    private let onHeld: @Sendable () -> Void
    private var removeFailures: Int
    private var registry: [String: String] = [:]
    private var registered: [SessionActivityPushRequest] = []
    private var removed: [SessionActivityPushRequest] = []
    private var removeAttempts: [SessionActivityPushRequest] = []
    private var heldContinuation: CheckedContinuation<Void, Never>?

    init(heldToken: String? = nil, removeFailures: Int = 0,
         registerFailuresAfterWrite: Int = 0, rejectCancelledRegistrations: Bool = false,
         registerFailureIsCancellation: Bool = false, refusedStatus: Int? = nil,
         onHeld: @escaping @Sendable () -> Void = {}) {
        self.heldToken = heldToken
        self.removeFailures = removeFailures
        self.registerFailuresAfterWrite = registerFailuresAfterWrite
        self.rejectCancelledRegistrations = rejectCancelledRegistrations
        self.registerFailureIsCancellation = registerFailureIsCancellation
        self.refusedStatus = refusedStatus
        self.onHeld = onHeld
    }

    func register(_ request: SessionActivityPushRequest) async throws {
        registered.append(request)
        if let refusedStatus { throw SessionActivityPushServiceError.refused(status: refusedStatus) }
        if request.pushToken == heldToken {
            onHeld()
            await withCheckedContinuation { heldContinuation = $0 }
        }
        if rejectCancelledRegistrations, Task.isCancelled { throw CancellationError() }
        registry[request.scope.activityID] = request.pushToken
        if registerFailuresAfterWrite > 0 {
            registerFailuresAfterWrite -= 1
            if registerFailureIsCancellation { throw CancellationError() }
            throw URLError(.timedOut)
        }
    }

    func remove(_ request: SessionActivityPushRequest) async throws {
        removeAttempts.append(request)
        if removeFailures > 0 {
            removeFailures -= 1
            throw URLError(.networkConnectionLost)
        }
        removed.append(request)
        if registry[request.scope.activityID] == request.pushToken {
            registry[request.scope.activityID] = nil
        }
    }

    func releaseHeldRegister() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func state() -> State {
        State(registry: registry, registered: registered, removed: removed,
              removeAttempts: removeAttempts)
    }
}
