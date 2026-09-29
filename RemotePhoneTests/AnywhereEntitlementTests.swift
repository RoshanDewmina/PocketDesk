import XCTest
@testable import PocketDeskRemote

/// The entitlement rules, the paywall's words and the service address, without StoreKit.
final class AnywhereEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func snap(_ renewal: SubscriptionSnapshot.Renewal, _ product: String = AnywherePlan.yearlyID,
                      ends: TimeInterval? = 86_400, trial: Bool = false, grace: TimeInterval? = nil,
                      revoked: Bool = false, verified: Bool = true) -> SubscriptionSnapshot {
        SubscriptionSnapshot(renewal: renewal, productID: product, expirationDate: ends.map { now.addingTimeInterval($0) },
                             revocationDate: revoked ? now : nil, isFreeTrial: trial, willAutoRenew: true,
                             gracePeriodExpirationDate: grace.map { now.addingTimeInterval($0) }, verified: verified,
                             signedTransaction: "jws-\(renewal)")
    }

    func testPhasesAndAccess() {
        XCTAssertEqual(AnywhereEntitlement.resolve([], now: now).phase, .notSubscribed)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed, trial: true)], now: now).phase, .trial)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed)], now: now).phase, .active)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.gracePeriod, ends: -60, grace: 3_600)], now: now).phase, .gracePeriod)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.gracePeriod, ends: -60, grace: -1)], now: now).phase, .billingRetry,
                       "A lapsed grace period is billing retry, with no access")
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.billingRetry, ends: -60)], now: now).phase, .billingRetry)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.expired, ends: -60)], now: now).phase, .expired)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed, ends: -1)], now: now).phase, .expired,
                       "A subscribed status past its expiry does not grant access")
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed, revoked: true)], now: now).phase, .revoked,
                       "A refund or revocation wins over the renewal state")
        for phase in [AnywhereEntitlement.Phase.trial, .active, .gracePeriod] {
            XCTAssertTrue(AnywhereEntitlement(phase: phase).hasAccess)
        }
        for phase in [AnywhereEntitlement.Phase.unknown, .notSubscribed, .billingRetry, .expired, .revoked] {
            XCTAssertFalse(AnywhereEntitlement(phase: phase).hasAccess)
        }
    }

    func testUnverifiedAndForeignStatusesNeverGrant() {
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed, verified: false)], now: now).phase, .notSubscribed)
        XCTAssertEqual(AnywhereEntitlement.resolve([snap(.subscribed, "com.example.other")], now: now).phase, .notSubscribed)
    }

    func testStrongestStatusAndItsTransactionWin() {
        let best = AnywhereEntitlement.best([snap(.expired, ends: -60), snap(.subscribed, AnywherePlan.monthlyID), snap(.revoked)], now: now)
        XCTAssertEqual(best.entitlement.phase, .active)
        XCTAssertEqual(best.entitlement.productID, AnywherePlan.monthlyID)
        XCTAssertEqual(best.snapshot?.signedTransaction, "jws-subscribed")
    }

    private let yearly = PlanOffer(id: AnywherePlan.yearlyID, period: .year, displayPrice: "$49.99", price: Decimal(string: "49.99")!,
                                   currencyCode: "CAD", trialPhrase: "7-day")
    private let monthly = PlanOffer(id: AnywherePlan.monthlyID, period: .month, displayPrice: "$5.99", price: Decimal(string: "5.99")!,
                                    currencyCode: "CAD", trialPhrase: nil)

    func testDisclosureStatesPricePeriodTrialRenewalAndCancellation() {
        let text = AnywhereCopy.disclosure(yearly)
        for part in ["7-day free trial", "$49.99 a year", "renews automatically", "charged when the trial ends",
                     "24 hours before the end of the trial", "Settings › Apple Account › Subscriptions", "up to three of your iPhones and iPads",
                     "same Wi-Fi stays free"] {
            XCTAssertTrue(text.contains(part), "Missing “\(part)” in: \(text)")
        }
        XCTAssertTrue(AnywhereCopy.disclosure(monthly).contains("charged when you confirm"))
        XCTAssertEqual(AnywhereCopy.summary(yearly), "7-day free trial, then $49.99 a year. Renews automatically; cancel anytime.")
        XCTAssertEqual(AnywhereCopy.primaryTitle(yearly), "Start 7-day free trial")
        XCTAssertEqual(AnywhereCopy.primaryTitle(monthly), "Subscribe for $5.99 a month")
    }

    func testOfferArithmetic() {
        XCTAssertEqual(PlanOffer.yearlySaving(yearly: yearly, monthly: monthly), 30, "49.99 against 12 × 5.99 = 71.88")
        XCTAssertNotNil(yearly.monthlyEquivalent)
        XCTAssertTrue(yearly.monthlyEquivalent?.contains("4.17") == true, yearly.monthlyEquivalent ?? "nil")
        XCTAssertNil(monthly.monthlyEquivalent)
        XCTAssertEqual(PlanOffer.trialPhrase(unit: .weekOfYear, value: 1), "7-day")
        XCTAssertEqual(PlanOffer.trialPhrase(unit: .month, value: 1), "1-month")
        XCTAssertNil(PlanOffer.trialPhrase(unit: .day, value: 0))
    }

    func testHomeCaptionNeverSuggestsAccessWithoutIt() {
        XCTAssertEqual(AnywhereCopy.homeCaption(.notSubscribed), "Free on the same Wi-Fi · Anywhere off")
        XCTAssertEqual(AnywhereCopy.homeCaption(AnywhereEntitlement(phase: .revoked)), "Free on the same Wi-Fi · Anywhere off")
        XCTAssertEqual(AnywhereCopy.homeCaption(AnywhereEntitlement(phase: .billingRetry)), "Payment problem · paused")
        XCTAssertTrue(AnywhereCopy.homeCaption(AnywhereEntitlement(phase: .trial, periodEnd: now)).hasPrefix("Trial · ends"))
    }

    func testServiceAddress() {
        XCTAssertEqual(AnywhereService.baseURL(configured: "https://api.getfarside.com/", pairingServer: "wss://other.example/signal",
                                               allowDerived: true)?.absoluteString, "https://api.getfarside.com")
        XCTAssertEqual(AnywhereService.baseURL(configured: "", pairingServer: "wss://relay.example/signal", allowDerived: true)?.absoluteString,
                       "https://relay.example")
        XCTAssertEqual(AnywhereService.baseURL(configured: nil, pairingServer: "ws://127.0.0.1:8787/signal", allowDerived: true)?.absoluteString,
                       "http://127.0.0.1:8787")
        XCTAssertNil(AnywhereService.baseURL(configured: "", pairingServer: "wss://relay.example/signal", allowDerived: false),
                     "Release builds never send a transaction to an address from a pairing code")
        XCTAssertNil(AnywhereService.baseURL(configured: "http://plain.example", pairingServer: nil, allowDerived: false), "https only")
    }

    func testEntitlementRequiredShowsTheAnywhereScreen() {
        let error = FriendlyError.from(status: "Connection service: entitlement_required. Check the Mac and retry.", previous: nil, macName: "Mac")
        XCTAssertEqual(error?.kind, .needsPlan)
        XCTAssertEqual(error?.action, .seePlans)
        XCTAssertEqual(error?.secondary, .retry, "Joining the Mac's Wi-Fi stays one tap away")
    }
}

// MARK: - Verify client (Backend/ENTITLEMENT-CONTRACT.md v1)

final class EntitlementClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> HTTPEntitlementClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let now = self.now
        return HTTPEntitlementClient(baseURL: URL(string: "https://api.example")!, session: URLSession(configuration: configuration),
                                     now: { now })
    }

    private func verify() async throws -> EntitlementGrant {
        try await client().verify(EntitlementVerifyRequest(signedTransaction: "jws", deviceID: String(repeating: "a", count: 64)))
    }

    private func expectError(_ expected: EntitlementServiceError, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await verify(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? EntitlementServiceError, expected, file: file, line: line) }
    }

    func testRequestAndEntitledAnswerFollowTheContract() async throws {
        var seen: URLRequest?
        var body: [String: String] = [:]
        StubProtocol.handler = { request in
            seen = request
            body = (try? JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: String]) ?? [:]
            return (200, Data("""
            {"entitled":true,"expiresAt":"2026-10-06T12:00:00Z","environment":"Sandbox","productId":"com.roshan.PocketDesk.remote.yearly",
             "inGracePeriod":true,"entitlementToken":"fe1.cGF5bG9hZA.c2ln","tokenExpiresAt":"2026-09-30T12:00:00.000Z"}
            """.utf8))
        }
        let grant = try await verify()
        XCTAssertEqual(seen?.url?.absoluteString, "https://api.example/v1/entitlements/verify")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body, ["signedTransaction": "jws", "deviceId": String(repeating: "a", count: 64)])
        XCTAssertTrue(grant.entitled)
        XCTAssertTrue(grant.inGracePeriod)
        XCTAssertEqual(grant.environment, "Sandbox")
        XCTAssertEqual(grant.token, "fe1.cGF5bG9hZA.c2ln", "The token is kept verbatim, never parsed")
        XCTAssertEqual(grant.tokenExpiresAt, EntitlementWire.date("2026-09-30T12:00:00Z"))
        XCTAssertEqual(grant.expiresAt, EntitlementWire.date("2026-10-06T12:00:00Z"))
        XCTAssertEqual(grant.issuedAt, now)
    }

    func testNotEntitledCarriesItsReasonAndNoToken() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"entitled":false,"reason":"device_limit","environment":"Production","entitlementToken":"x"}"#.utf8)) }
        let grant = try await verify()
        XCTAssertFalse(grant.entitled)
        XCTAssertEqual(grant.reason, "device_limit")
        XCTAssertNil(grant.token, "A refusal never yields a token")
        XCTAssertFalse(grant.tokenValid(at: now))
    }

    func testErrorsMapToRefusalBackoffAndOutage() async {
        StubProtocol.handler = { _ in (401, Data(#"{"error":"invalid_transaction","reason":"environment_not_accepted"}"#.utf8)) }
        await expectError(.rejected(status: 401, reason: "environment_not_accepted"))
        StubProtocol.handler = { _ in (400, Data(#"{"error":"invalid_request"}"#.utf8)) }
        await expectError(.rejected(status: 400, reason: "invalid_request"))
        StubProtocol.handler = { _ in (429, Data(#"{"error":"rate_limited","retryAfterSeconds":42}"#.utf8)) }
        await expectError(.rateLimited(retryAfter: 42))
        StubProtocol.handler = { _ in (503, Data(#"{"error":"unavailable"}"#.utf8)) }
        await expectError(.unreachable)
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectError(.unreachable)
        StubProtocol.handler = { _ in (200, Data("not json".utf8)) }
        await expectError(.invalidResponse)
    }

    func testRefreshScheduleFollowsTheTwelveAndSixHourRules() throws {
        let day = EntitlementGrant(entitled: true, token: "fe1.a.b", tokenExpiresAt: now.addingTimeInterval(24 * 3600), issuedAt: now)
        XCTAssertFalse(day.needsRefresh(at: now.addingTimeInterval(11 * 3600)))
        XCTAssertTrue(day.needsRefresh(at: now.addingTimeInterval(12 * 3600 + 1)), "Older than 12 hours")
        XCTAssertEqual(day.refreshDate(now: now), now.addingTimeInterval(12 * 3600))
        let short = EntitlementGrant(entitled: true, token: "fe1.a.b", tokenExpiresAt: now.addingTimeInterval(5 * 3600), issuedAt: now)
        XCTAssertTrue(short.needsRefresh(at: now), "Less than 6 hours left, e.g. near the end of a period")
        let refresh = try XCTUnwrap(short.refreshDate(now: now))
        XCTAssertLessThan(refresh, now.addingTimeInterval(5 * 3600), "Always before it lapses")
        XCTAssertGreaterThan(refresh, now.addingTimeInterval(59))
        XCTAssertFalse(short.tokenValid(at: now.addingTimeInterval(5 * 3600 - 4)))
    }

    func testIdentityIsSixtyFourHexAndStable() throws {
        InstallIdentity.resetCacheForTesting()
        let store = MemoryStore()
        let first = try XCTUnwrap(InstallIdentity.current(store: store))
        XCTAssertTrue(SecureRandom.isToken(first.deviceID), "64 lowercase hex, contract §1")
        InstallIdentity.resetCacheForTesting()
        XCTAssertEqual(InstallIdentity.current(store: store), first, "Read back from the Keychain, never regenerated")
        InstallIdentity.resetCacheForTesting()
        XCTAssertNil(InstallIdentity.current(store: FailingStore()), "A locked Keychain never invents a second identity")
        InstallIdentity.resetCacheForTesting()
    }
}

final class MemoryStore: PairPersistence {
    private var data: Data?
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

private struct FailingStore: PairPersistence {
    func save<T: Encodable>(_ value: T) throws { throw RemoteError.keychain(-25308) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { throw RemoteError.keychain(-25308) }
    func delete() throws {}
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

// MARK: - Handshake

@MainActor
final class AnywhereAccessTests: XCTestCase {
    private final class Source: AnywhereEntitlementSource {
        var entitlement = AnywhereEntitlement.notSubscribed
        func signedTransaction() async -> String? { entitlement.hasAccess ? "jws" : nil }
    }

    private final class Verifier: EntitlementVerifying {
        var answers: [Result<EntitlementGrant, EntitlementServiceError>] = []
        var requests: [EntitlementVerifyRequest] = []
        var delay: Duration = .zero
        func verify(_ request: EntitlementVerifyRequest) async throws -> EntitlementGrant {
            requests.append(request)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return try (answers.isEmpty ? .failure(.unreachable) : answers.removeFirst()).get()
        }
    }

    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private let source = Source()
    private let verifier = Verifier()
    private let keychain = MemoryStore()
    private var serviceURL: URL? = URL(string: "https://api.example")
    private let device = String(repeating: "b", count: 64)

    private func makeAccess() -> AnywhereAccess {
        let verifier = self.verifier
        let device = self.device
        let access = AnywhereAccess(source: source, makeClient: { _ in verifier }, deviceID: { device },
                                    now: { [unowned self] in self.clock }, persistence: keychain)
        access.serviceURL = { [unowned self] in self.serviceURL }
        return access
    }

    private func grant(_ token: String = "fe1.t.s", ttl: TimeInterval = 24 * 3600) -> EntitlementGrant {
        EntitlementGrant(entitled: true, expiresAt: clock.addingTimeInterval(7 * 86_400), environment: "Sandbox",
                         token: token, tokenExpiresAt: clock.addingTimeInterval(ttl), issuedAt: clock)
    }

    func testWithoutAPlanNothingIsSentAndTheAnswerIsThePaywall() async {
        let access = makeAccess()
        let verified = await access.refresh()
        XCTAssertFalse(verified)
        XCTAssertTrue(verifier.requests.isEmpty)
        XCTAssertNil(access.currentToken())
        let outcome = await access.resolveEntitlementRequired()
        XCTAssertEqual(outcome, .showPaywall)
    }

    func testTokenIsKeptInTheKeychainAndReusedUntilDue() async {
        source.entitlement = AnywhereEntitlement(phase: .trial)
        verifier.answers = [.success(grant("fe1.first.s"))]
        let access = makeAccess()
        let verified = await access.refresh()
        XCTAssertTrue(verified)
        XCTAssertEqual(verifier.requests, [EntitlementVerifyRequest(signedTransaction: "jws", deviceID: device)])
        XCTAssertEqual(access.currentToken(), "fe1.first.s")
        XCTAssertEqual(access.verification, .verified)

        source.entitlement = .unknown
        let relaunched = makeAccess()
        XCTAssertEqual(relaunched.currentToken(), "fe1.first.s", "A relaunch presents the saved token before StoreKit answers")
        source.entitlement = AnywhereEntitlement(phase: .trial)
        await relaunched.refresh()
        XCTAssertEqual(verifier.requests.count, 1, "A fresh token is not re-verified")

        clock = clock.addingTimeInterval(12 * 3600 + 60)
        verifier.answers = [.success(grant("fe1.second.s"))]
        await relaunched.refresh()
        XCTAssertEqual(verifier.requests.count, 2, "Older than 12 hours: ask again")
        XCTAssertEqual(relaunched.currentToken(), "fe1.second.s")
        clock = clock.addingTimeInterval(25 * 3600)
        XCTAssertNil(relaunched.currentToken(), "An expired token is never presented")
    }

    func testLosingTheSubscriptionDropsTheSavedToken() async {
        source.entitlement = AnywhereEntitlement(phase: .active)
        verifier.answers = [.success(grant())]
        let access = makeAccess()
        await access.refresh()
        XCTAssertNotNil(access.currentToken())
        source.entitlement = AnywhereEntitlement(phase: .revoked)
        XCTAssertNil(access.currentToken(), "A refund ends the token on this phone at once")
        access.entitlementChanged()
        XCTAssertNil(access.grant)
        XCTAssertNil(try keychain.read(EntitlementGrant.self), "Deleted from the Keychain too")
    }

    func testAnOutageNeverBlocksAConnectionForLongAndKeepsAValidToken() async {
        source.entitlement = AnywhereEntitlement(phase: .active)
        verifier.delay = .milliseconds(1500)
        let access = makeAccess()
        let started = Date()
        await access.prepareForConnection(timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2, "A slow service must not hold up a same-Wi-Fi connection")
        XCTAssertNil(access.currentToken())
        try? await Task.sleep(for: .milliseconds(1600))
        verifier.delay = .zero

        verifier.answers = [.success(grant())]
        await access.refresh(force: true)
        verifier.answers = [.failure(.unreachable)]
        let kept = await access.refresh(force: true)
        XCTAssertTrue(kept, "A 503 keeps using the unexpired token (contract §2)")
        XCTAssertEqual(access.verification, .unreachable)
        XCTAssertNotNil(access.currentToken())
    }

    func testRateLimitBacksOff() async {
        source.entitlement = AnywhereEntitlement(phase: .active)
        verifier.answers = [.failure(.rateLimited(retryAfter: 30))]
        let access = makeAccess()
        await access.refresh(force: true)
        await access.refresh(force: true)
        XCTAssertEqual(verifier.requests.count, 1, "No second call inside retryAfterSeconds")
        clock = clock.addingTimeInterval(31)
        verifier.answers = [.success(grant())]
        await access.refresh(force: true)
        XCTAssertEqual(verifier.requests.count, 2)
        XCTAssertNotNil(access.currentToken())
    }

    func testRefusalReasonAndMissingServiceAddress() async {
        source.entitlement = AnywhereEntitlement(phase: .active)
        let refusal = EntitlementGrant(entitled: false, reason: "device_limit", issuedAt: clock)
        verifier.answers = [.success(refusal)]
        let access = makeAccess()
        let refused = await access.refresh()
        XCTAssertFalse(refused)
        XCTAssertEqual(access.verification, .refused(reason: "device_limit"))
        XCTAssertTrue(AnywhereCopy.refusal("device_limit").contains("three devices"))
        serviceURL = nil
        let unconfigured = await access.refresh(force: true)
        XCTAssertFalse(unconfigured)
        XCTAssertEqual(access.verification, .notConfigured)
        XCTAssertEqual(verifier.requests.count, 1, "No address, no request")
    }

    func testEntitlementRequiredWithAPlanReverifiesAndReconnectsOnce() async throws {
        source.entitlement = AnywhereEntitlement(phase: .gracePeriod)
        let access = makeAccess()
        let transport = FakeSignalingTransport()
        let connection = try pairedPhone(transport)
        connection.advertisesRemoteAccess = true
        connection.entitlementToken = { [weak access] in access?.currentToken() }
        connection.start()
        XCTAssertEqual(transport.connects.count, 1)

        verifier.answers = [.success(grant("fe1.renewed.s"))]
        await access.serviceAskedForEntitlement(connection)
        XCTAssertEqual(access.currentToken(), "fe1.renewed.s")
        XCTAssertEqual(transport.connects.count, 2, "Reconnects so the service can add internet routes")

        verifier.answers = [.success(grant("fe1.again.s"))]
        await access.serviceAskedForEntitlement(connection)
        XCTAssertEqual(transport.connects.count, 2, "Never more than one such reconnect a minute")

        verifier.answers = [.failure(.rejected(status: 401, reason: "signature"))]
        let outcome = await access.resolveEntitlementRequired()
        XCTAssertEqual(outcome, .cannotVerify)
        XCTAssertNil(access.currentToken())
        connection.stop()
    }

    // MARK: Signaling (contract §4)

    private func pairedPhone(_ transport: any SignalingTransport) throws -> RemoteCoordinator {
        let invitation = try HostPair.create(server: "wss://relay.example/signal", name: "Studio Mac").invitation
        let connection = RemoteCoordinator(isHost: false, store: InMemoryPairStore(invitation: invitation), signaling: transport)
        connection.restore()
        return connection
    }

    func testPhoneRegistrationListsRemoteAndPresentsTheToken() throws {
        let transport = RecordingTransport()
        let connection = try pairedPhone(transport)
        connection.start()
        XCTAssertEqual(transport.registrations.last?.features, [SignalingFeature.renewal], "Unchanged until Anywhere is attached")
        XCTAssertEqual(transport.registrations.last?.entitlement, .some(nil))
        connection.advertisesRemoteAccess = true
        connection.entitlementToken = { "fe1.t.s" }
        connection.start()
        XCTAssertEqual(transport.registrations.last?.features, [SignalingFeature.renewal, "remote.1"])
        XCTAssertEqual(transport.registrations.last?.entitlement, "fe1.t.s")
        connection.entitlementToken = { nil }
        connection.start()
        XCTAssertEqual(transport.registrations.last?.entitlement, .some(nil), "No plan still registers, without a token")
        connection.stop()

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(RelayMessage(type: "register", entitlement: "fe1.t.s")), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""entitlement":"fe1.t.s""#))
        let plain = try XCTUnwrap(String(data: JSONEncoder().encode(RelayMessage(type: "register")), encoding: .utf8))
        XCTAssertFalse(plain.contains("entitlement"), "Absent, not null, without a plan")
    }

    func testEntitlementRequiredIsNonClosingAndTheSessionGoesOnLocally() async throws {
        let transport = FakeSignalingTransport()
        transport.replies = [
            RelayMessage(type: "error", code: "entitlement_required"),
            try JSONDecoder().decode(RelayMessage.self, from: Data(#"{"type":"registered","role":"client","access":"local"}"#.utf8)),
            RelayMessage(type: "ice", servers: [])
        ]
        let connection = try pairedPhone(transport)
        connection.advertisesRemoteAccess = true
        connection.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(connection.entitlementRequired)
        XCTAssertEqual(connection.serviceAccess, "local")
        XCTAssertTrue(connection.isRunning, "Same-network sessions continue")
        XCTAssertEqual(connection.status, "Connecting securely…")
        XCTAssertEqual(transport.closeCount, 0, "The error closed nothing")
        connection.start()
        XCTAssertEqual(connection.entitlementRequired, false, "Each attempt starts clean")
        connection.stop()
    }

    func testAFailedLocalOnlyAttemptOffersAnywhere() {
        let unreachable = FriendlyError.unreachable("Studio Mac")
        XCTAssertEqual(FriendlyError.forLocalOnly(unreachable, serviceAskedForAnywhere: true, hasPlan: false).kind, .needsPlan)
        XCTAssertEqual(FriendlyError.forLocalOnly(unreachable, serviceAskedForAnywhere: true, hasPlan: true).kind, .anywhereUnverified)
        XCTAssertEqual(FriendlyError.forLocalOnly(unreachable, serviceAskedForAnywhere: false, hasPlan: false).kind, .unreachable,
                       "An older service, or a remote-allowed session, keeps the ordinary explanation")
        XCTAssertEqual(FriendlyError.forLocalOnly(.declined, serviceAskedForAnywhere: true, hasPlan: false).kind, .declined)
    }
}

@MainActor
private final class RecordingTransport: SignalingTransport {
    struct Registration { var features: [String]; var entitlement: String? }
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    private(set) var registrations: [Registration] = []

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        try connect(invitation: invitation, hostToken: hostToken, features: features, entitlement: nil)
    }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        registrations.append(Registration(features: features, entitlement: entitlement))
    }
    func send(_ message: RelayMessage) {}
    func close() {}
}
