import XCTest
import Foundation

private final class MemoryPairStore: PairPersistence {
    var data: Data?
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

/// A clock the test moves by hand. Sleepers resume in deadline order as time is advanced.
private final class ManualScheduler: RenewalScheduler, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var nextID = 0
    private var sleepers: [Sleeper] = []
    private var cancelledEarly: Set<Int> = []

    func now() -> TimeInterval { lock.withLock { current } }

    func sleep(seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledEarly.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: current + seconds, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledEarly.insert(id)
                lock.unlock()
            }
        }
    }

    var sleeping: Int { lock.withLock { sleepers.count } }

    @MainActor
    func advance(by seconds: TimeInterval) async {
        let target = now() + seconds
        while true {
            let due: Sleeper? = lock.withLock {
                guard let sleeper = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else {
                    current = target
                    return nil
                }
                sleepers.removeAll { $0.id == sleeper.id }
                current = max(current, sleeper.deadline)
                return sleeper
            }
            guard let sleeper = due else { break }
            sleeper.continuation.resume()
            await settle()
        }
        await settle()
    }

    @MainActor
    func settle() async { for _ in 0..<12 { await Task.yield() } }
}

@MainActor
private final class ScriptedSignaling: SignalingTransport {
    struct Connect {
        let invitation: PairInvitation
        let hostToken: String?
        let features: [String]
    }
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    var onConnect: ((Connect) -> Void)?
    var respond: ((RelayMessage) -> Void)?
    private(set) var connects: [Connect] = []
    private(set) var sent: [RelayMessage] = []
    private(set) var isOpen = false

    var renewals: [RelayMessage] { sent.filter { $0.type == "renew" } }

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        let record = Connect(invitation: invitation, hostToken: hostToken, features: features)
        connects.append(record)
        isOpen = true
        Task { @MainActor [weak self] in self?.onConnect?(record) }
    }

    func send(_ message: RelayMessage) {
        sent.append(message)
        respond?(message)
    }

    func close() { isOpen = false }
    func deliver(_ message: RelayMessage) { onMessage?(message) }

    func serverCloses() {
        guard isOpen else { return }
        isOpen = false
        onClose?()
    }
}

/// The service side of renewal, following the rules in Server/src/server.ts: a lease that a renewal
/// extends and that closes the connection when it runs out, and relay credentials refreshed once a
/// third of their life is spent.
@MainActor
private final class SimulatedService {
    private let signaling: ScriptedSignaling
    private let scheduler: ManualScheduler
    private let leaseSeconds: Double
    private let credentialSeconds: Double?
    private var leaseEndsAt: Double = 0
    private var leaseTask: Task<Void, Never>?
    private var lastIssuedAt: Double = 0
    private var role = "host"
    private(set) var issued: [(username: String, expiresAt: Double)] = []
    private(set) var leaseExpiries = 0
    private(set) var renewalsHandled = 0

    init(signaling: ScriptedSignaling, scheduler: ManualScheduler, leaseSeconds: Double, credentialSeconds: Double?) {
        self.signaling = signaling
        self.scheduler = scheduler
        self.leaseSeconds = leaseSeconds
        self.credentialSeconds = credentialSeconds
    }

    func accept(role: String, features: [String], offersRenewal: Bool) {
        self.role = role
        armLease()
        let servers = issue()
        var offer: RenewalOffer?
        if features.contains(SignalingFeature.renewal), offersRenewal {
            offer = RenewalOffer(version: 1, leaseSeconds: leaseSeconds, renewAfterSeconds: nextRenewAfter(),
                                 credentialSeconds: credentialSeconds)
        }
        signaling.deliver(RelayMessage(type: "registered", role: role, renew: offer))
        signaling.deliver(RelayMessage(type: "ice", servers: servers))
    }

    func handle(_ message: RelayMessage) {
        guard message.type == "renew" else { return }
        renewalsHandled += 1
        guard scheduler.now() < leaseEndsAt else { expire(); return }
        armLease()
        var servers: [ICEServerConfiguration]?
        if let ttl = credentialSeconds, scheduler.now() - lastIssuedAt >= ttl / 3 { servers = issue() }
        signaling.deliver(RelayMessage(type: "renewed", servers: servers, leaseSeconds: leaseSeconds,
                                       renewAfterSeconds: nextRenewAfter(),
                                       credentialSeconds: servers == nil ? nil : credentialSeconds))
    }

    func isCurrent(username: String) -> Bool {
        issued.first { $0.username == username }.map { $0.expiresAt > scheduler.now() } ?? false
    }

    private func armLease() {
        leaseTask?.cancel()
        leaseEndsAt = scheduler.now() + leaseSeconds
        let scheduler = scheduler, lease = leaseSeconds
        leaseTask = Task { [weak self] in
            do { try await scheduler.sleep(seconds: lease) } catch { return }
            self?.expire()
        }
    }

    private func expire() {
        leaseExpiries += 1
        leaseTask?.cancel()
        signaling.serverCloses()
    }

    private func issue() -> [ICEServerConfiguration] {
        guard let ttl = credentialSeconds else { return [ICEServerConfiguration(urls: ["stun:stun.example.test:3478"])] }
        let username = "\(role)-\(issued.count + 1)"
        issued.append((username, scheduler.now() + ttl))
        lastIssuedAt = scheduler.now()
        return [ICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
                ICEServerConfiguration(urls: ["turn:relay.example.test:3478"], username: username, credential: "credential-\(username)")]
    }

    private func nextRenewAfter() -> Double {
        var candidates = [leaseSeconds / 2]
        if let ttl = credentialSeconds { candidates.append(max(0, lastIssuedAt + ttl / 3 - scheduler.now())) }
        return max(0.25, candidates.min() ?? leaseSeconds / 2)
    }
}

@MainActor
private final class Rig {
    let scheduler = ManualScheduler()
    let signaling = ScriptedSignaling()
    let service: SimulatedService
    let coordinator: RemoteCoordinator
    private let offersRenewal: Bool

    init(isHost: Bool, advertisesRenewal: Bool = true, serviceOffersRenewal: Bool = true, serviceResponds: Bool = true,
         leaseSeconds: Double = 1800, credentialSeconds: Double? = 3600) {
        offersRenewal = serviceOffersRenewal
        service = SimulatedService(signaling: signaling, scheduler: scheduler, leaseSeconds: leaseSeconds,
                                   credentialSeconds: credentialSeconds)
        coordinator = RemoteCoordinator(isHost: isHost, store: MemoryPairStore(), retryLimit: 3,
                                        retryBaseNanoseconds: 10_000_000, registrationStableNanoseconds: 50_000_000,
                                        signaling: signaling, renewalScheduler: scheduler,
                                        advertisesRenewal: advertisesRenewal)
        signaling.onConnect = { [weak self] connect in
            guard let self else { return }
            self.service.accept(role: connect.hostToken == nil ? "client" : "host", features: connect.features,
                                offersRenewal: self.offersRenewal)
        }
        if serviceResponds {
            signaling.respond = { [weak self] message in Task { @MainActor in self?.service.handle(message) } }
        }
    }

    func startHost() async throws {
        _ = try coordinator.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
        coordinator.start()
        await scheduler.settle()
    }

    func startPhone() async throws {
        let mac = RemoteCoordinator(isHost: true, store: MemoryPairStore())
        let invitation = try mac.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
        try coordinator.enroll(invitation.code())
        await scheduler.settle()
    }

    var heldRelayUsername: String? { coordinator.iceServersForTesting.compactMap(\.username).first }
}

final class SessionRenewalPlanTests: XCTestCase {
    private let offer = RenewalOffer(version: 1, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600)

    func testTheFirstRenewalIsDueWhenTheServiceAsks() {
        let plan = RenewalPlan(offer: offer, now: 100)
        XCTAssertEqual(plan.nextAttemptAt, 1000)
        XCTAssertEqual(plan.delay(from: 100), 900)
        XCTAssertEqual(plan.delay(from: 5000), 0)
        XCTAssertFalse(plan.isDue(at: 999.9))
        XCTAssertTrue(plan.isDue(at: 1000))
        XCTAssertEqual(plan.leaseEndsAt, 1900)
        XCTAssertEqual(plan.credentialsEndAt, 3700)
    }

    func testIntervalsAndDeadlinesFromAHostileOrBrokenServiceAreBounded() {
        XCTAssertEqual(RenewalPlan(offer: RenewalOffer(version: 1, renewAfterSeconds: 0.001), now: 0).nextAttemptAt, 0.25)
        XCTAssertEqual(RenewalPlan(offer: RenewalOffer(version: 1, renewAfterSeconds: 1e9), now: 0).nextAttemptAt, 3600)
        XCTAssertEqual(RenewalPlan(offer: RenewalOffer(version: 1, renewAfterSeconds: .nan), now: 0).nextAttemptAt, 3600)
        XCTAssertEqual(RenewalPlan(offer: RenewalOffer(version: 1, renewAfterSeconds: -5), now: 0).nextAttemptAt, 0.25)
        let odd = RenewalPlan(offer: RenewalOffer(version: 1, leaseSeconds: -1, renewAfterSeconds: 10, credentialSeconds: .infinity), now: 0)
        XCTAssertNil(odd.leaseEndsAt)
        XCTAssertNil(odd.credentialsEndAt)
        XCTAssertFalse(odd.leaseExpired(at: 1e9))
        XCTAssertFalse(odd.credentialsExpired(at: 1e9))
    }

    func testASuccessfulRenewalMovesTheDeadlinesAndClearsFailures() {
        var plan = RenewalPlan(offer: offer, now: 0)
        plan.attemptStarted(at: 900)
        plan.attemptStarted(at: 910)
        XCTAssertEqual(plan.failures, 1)
        plan.renewed(RenewalOutcome(leaseSeconds: 1800, renewAfterSeconds: 300, credentialSeconds: 3600), at: 915)
        XCTAssertEqual(plan.failures, 0)
        XCTAssertFalse(plan.attemptOutstanding)
        XCTAssertEqual(plan.nextAttemptAt, 1215)
        XCTAssertEqual(plan.leaseEndsAt, 2715)
        XCTAssertEqual(plan.credentialsEndAt, 4515)
    }

    func testARenewalWithoutNewCredentialsKeepsTheOldCredentialDeadline() {
        var plan = RenewalPlan(offer: offer, now: 0)
        plan.attemptStarted(at: 900)
        plan.renewed(RenewalOutcome(leaseSeconds: 1800, renewAfterSeconds: 300, credentialSeconds: nil), at: 901)
        XCTAssertEqual(plan.leaseEndsAt, 2701)
        XCTAssertEqual(plan.credentialsEndAt, 3600)
        plan.attemptStarted(at: 1200)
        plan.renewed(RenewalOutcome(leaseSeconds: 1800, renewAfterSeconds: 30, credentialSeconds: nil, softFailure: "relay_unavailable"), at: 1200)
        XCTAssertEqual(plan.credentialsEndAt, 3600)
        XCTAssertEqual(plan.nextAttemptAt, 1230)
    }

    func testUnansweredAttemptsRetryAfterTheResponseTimeoutAndBackOffToAThirtySecondCeiling() {
        var plan = RenewalPlan(offer: offer, now: 0)
        var times: [TimeInterval] = []
        var now = plan.nextAttemptAt
        for _ in 0..<8 {
            plan.attemptStarted(at: now)
            times.append(now)
            now = plan.nextAttemptAt
        }
        XCTAssertEqual(times, [900, 910, 920, 930, 940, 956, 986, 1016])
    }

    func testAnUnusableReplyBacksOffBeforeTheNextAttempt() {
        var plan = RenewalPlan(offer: offer, now: 0)
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            plan.attemptStarted(at: 1000)
            plan.attemptFailed(at: 1000)
            delays.append(plan.nextAttemptAt - 1000)
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30])
        plan.renewed(RenewalOutcome(leaseSeconds: 1800, renewAfterSeconds: 900), at: 2000)
        XCTAssertEqual(plan.failures, 0)
    }

    func testLeaseAndCredentialExpiryAreReportedFromTheLastGoodRenewal() {
        var plan = RenewalPlan(offer: RenewalOffer(version: 1, leaseSeconds: 60, renewAfterSeconds: 30, credentialSeconds: 120), now: 0)
        XCTAssertFalse(plan.leaseExpired(at: 59.9))
        XCTAssertTrue(plan.leaseExpired(at: 60))
        XCTAssertFalse(plan.credentialsExpired(at: 119.9))
        XCTAssertTrue(plan.credentialsExpired(at: 120))
        plan.attemptStarted(at: 30)
        plan.renewed(RenewalOutcome(leaseSeconds: 60, renewAfterSeconds: 30, credentialSeconds: nil), at: 30)
        XCTAssertFalse(plan.leaseExpired(at: 89.9))
        XCTAssertTrue(plan.leaseExpired(at: 90))
    }

    func testAPlanThatKeepsRenewingNeverLapsesInOneHundredThirtyMinutesButOneThatStopsDoesAtThirty() {
        var renewing = RenewalPlan(offer: offer, now: 0)
        let silent = RenewalPlan(offer: offer, now: 0)
        var credentialsIssuedAt = 0.0
        var checkpoints: [Int] = []
        for minute in 1...130 {
            let now = TimeInterval(minute * 60)
            if renewing.isDue(at: now) {
                renewing.attemptStarted(at: now)
                let refresh = now - credentialsIssuedAt >= 1200
                if refresh { credentialsIssuedAt = now }
                let renewAfter = refresh ? 900 : min(900, credentialsIssuedAt + 1200 - now)
                renewing.renewed(RenewalOutcome(leaseSeconds: 1800, renewAfterSeconds: max(60, renewAfter),
                                                credentialSeconds: refresh ? 3600 : nil), at: now)
            }
            XCTAssertFalse(renewing.leaseExpired(at: now), "lease lapsed at minute \(minute)")
            XCTAssertFalse(renewing.credentialsExpired(at: now), "credentials lapsed at minute \(minute)")
            if [30, 60, 120].contains(minute) { checkpoints.append(minute) }
            XCTAssertEqual(silent.leaseExpired(at: now), minute >= 30)
        }
        XCTAssertEqual(checkpoints, [30, 60, 120])
    }

    func testRenewalMessagesRoundTripAndLegacyMessagesStayUnchanged() throws {
        let registered = try JSONDecoder().decode(RelayMessage.self, from: Data(
            #"{"type":"registered","role":"host","renew":{"version":1,"leaseSeconds":1800,"renewAfterSeconds":900,"credentialSeconds":3600}}"#.utf8))
        XCTAssertEqual(registered.renew, RenewalOffer(version: 1, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600))

        let legacy = try JSONDecoder().decode(RelayMessage.self, from: Data(#"{"type":"registered","role":"host"}"#.utf8))
        XCTAssertNil(legacy.renew)

        let renewed = try JSONDecoder().decode(RelayMessage.self, from: Data(
            #"{"type":"renewed","leaseSeconds":1800,"renewAfterSeconds":300,"servers":[{"urls":["turn:relay.example.test:3478"],"username":"host-3","credential":"c"}],"credentialSeconds":3600}"#.utf8))
        XCTAssertEqual(renewed.renewAfterSeconds, 300)
        XCTAssertEqual(renewed.servers?.first?.username, "host-3")
        XCTAssertEqual(renewed.credentialSeconds, 3600)

        let soft = try JSONDecoder().decode(RelayMessage.self, from: Data(
            #"{"type":"renewed","leaseSeconds":1800,"renewAfterSeconds":30,"code":"relay_unavailable"}"#.utf8))
        XCTAssertNil(soft.servers)
        XCTAssertEqual(soft.code, "relay_unavailable")

        let renew = String(decoding: try JSONEncoder().encode(RelayMessage(type: "renew")), as: UTF8.self)
        XCTAssertEqual(renew, #"{"type":"renew"}"#)
        let plainRegister = String(decoding: try JSONEncoder().encode(RelayMessage(type: "register", version: 1, role: "host")), as: UTF8.self)
        XCTAssertFalse(plainRegister.contains("features"))
        let renewingRegister = String(decoding: try JSONEncoder().encode(
            RelayMessage(type: "register", version: 1, role: "host", features: [SignalingFeature.renewal])), as: UTF8.self)
        XCTAssertTrue(renewingRegister.contains(#""features":["renew.1"]"#))
    }
}

@MainActor
final class CoordinatorRenewalTests: XCTestCase {
    private func waitFor(_ description: String, seconds: Double = 3, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    func testARenewingMacStaysRegisteredAndKeepsUsableRelayCredentialsPastThirtySixtyAndOneTwentyMinutes() async throws {
        let rig = Rig(isHost: true)
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal])
        XCTAssertTrue(rig.coordinator.hostRegistered)
        XCTAssertNotNil(rig.coordinator.renewalPlanForTesting)

        var checkpoints: [Int] = []
        for minute in 1...130 {
            await rig.scheduler.advance(by: 60)
            XCTAssertEqual(rig.signaling.connects.count, 1, "the signaling connection was replaced at minute \(minute)")
            XCTAssertTrue(rig.coordinator.hostRegistered, "the Mac stopped being registered at minute \(minute)")
            XCTAssertEqual(rig.coordinator.status, "Ready for your paired phone")
            let held = try XCTUnwrap(rig.heldRelayUsername, "no relay credential at minute \(minute)")
            XCTAssertTrue(rig.service.isCurrent(username: held), "the credential in use had expired at minute \(minute)")
            if [30, 60, 120].contains(minute) { checkpoints.append(minute) }
        }
        XCTAssertEqual(checkpoints, [30, 60, 120])
        XCTAssertEqual(rig.service.leaseExpiries, 0)
        XCTAssertGreaterThanOrEqual(rig.coordinator.credentialRefreshCount, 6)
        XCTAssertGreaterThan(rig.coordinator.renewalCount, 10)
        XCTAssertEqual(rig.coordinator.iceRestartCount, 0, "no live media, so nothing to restart")
        XCTAssertEqual(rig.signaling.renewals.count, rig.service.renewalsHandled)
    }

    func testAPhoneThatIsOfferedRenewalKeepsItsCredentialsFreshToo() async throws {
        let rig = Rig(isHost: false)
        try await rig.startPhone()
        XCTAssertNil(rig.signaling.connects[0].hostToken)
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal])
        for minute in 1...125 {
            await rig.scheduler.advance(by: 60)
            let held = try XCTUnwrap(rig.heldRelayUsername)
            XCTAssertTrue(rig.service.isCurrent(username: held), "the phone's credential had expired at minute \(minute)")
        }
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertGreaterThanOrEqual(rig.coordinator.credentialRefreshCount, 5)
    }

    func testAnAppThatDoesNotAskForRenewalSendsNothingNewAndEndsAtTheLeaseThenTheReconnectLogicRecovers() async throws {
        let rig = Rig(isHost: true, advertisesRenewal: false)
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects[0].features, [])
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        await rig.scheduler.advance(by: 1799)
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertTrue(rig.coordinator.hostRegistered)
        XCTAssertTrue(rig.signaling.renewals.isEmpty)

        await rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.service.leaseExpiries, 1)
        XCTAssertFalse(rig.coordinator.hostRegistered)
        XCTAssertTrue(rig.coordinator.status.contains("retrying"))

        try await waitFor("the existing bounded reconnect registered the Mac again") {
            rig.signaling.connects.count == 2 && rig.coordinator.hostRegistered
        }
        XCTAssertTrue(rig.signaling.renewals.isEmpty)
    }

    func testAServiceThatDoesNotOfferRenewalIsNeverSentRenew() async throws {
        let rig = Rig(isHost: true, serviceOffersRenewal: false)
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal])
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        await rig.scheduler.advance(by: 1700)
        XCTAssertTrue(rig.signaling.renewals.isEmpty)
        await rig.scheduler.advance(by: 100)
        XCTAssertEqual(rig.service.leaseExpiries, 1)
    }

    func testASilentServiceIsRetriedWithBackoffAndARepliesResetsTheSchedule() async throws {
        let rig = Rig(isHost: true, serviceResponds: false)
        try await rig.startHost()
        await rig.scheduler.advance(by: 899)
        XCTAssertEqual(rig.signaling.renewals.count, 0)
        await rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.signaling.renewals.count, 1)
        await rig.scheduler.advance(by: 60)
        XCTAssertEqual(rig.signaling.renewals.count, 6, "attempts at 900, 910, 920, 930, 940 and 956 seconds")
        await rig.scheduler.advance(by: 30)
        XCTAssertEqual(rig.signaling.renewals.count, 7)

        rig.signaling.deliver(RelayMessage(type: "renewed", leaseSeconds: 1800, renewAfterSeconds: 600))
        let sentBefore = rig.signaling.renewals.count
        await rig.scheduler.advance(by: 599)
        XCTAssertEqual(rig.signaling.renewals.count, sentBefore)
        await rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.signaling.renewals.count, sentBefore + 1)
        XCTAssertEqual(rig.coordinator.renewalCount, 1)
    }

    func testStoppingCancelsRenewalAndALateReplyIsIgnored() async throws {
        let rig = Rig(isHost: true)
        try await rig.startHost()
        await rig.scheduler.advance(by: 100)
        rig.coordinator.stop()
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        let sent = rig.signaling.renewals.count
        await rig.scheduler.advance(by: 4000)
        XCTAssertEqual(rig.signaling.renewals.count, sent)

        let servers = [ICEServerConfiguration(urls: ["turn:late.example.test:3478"], username: "late", credential: "c")]
        rig.signaling.deliver(RelayMessage(type: "renewed", servers: servers, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600))
        XCTAssertEqual(rig.coordinator.renewalCount, 0)
        XCTAssertEqual(rig.coordinator.credentialRefreshCount, 0)
        XCTAssertFalse(rig.coordinator.iceServersForTesting.contains { $0.username == "late" })
    }

    func testRefreshedServersWithoutARelayAreIgnoredAndRetried() async throws {
        let rig = Rig(isHost: true, serviceResponds: false)
        try await rig.startHost()
        let before = rig.coordinator.iceServersForTesting
        await rig.scheduler.advance(by: 900)
        XCTAssertEqual(rig.signaling.renewals.count, 1)

        let stunOnly = [ICEServerConfiguration(urls: ["stun:stun.example.test:3478"])]
        rig.signaling.deliver(RelayMessage(type: "renewed", servers: stunOnly, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600))
        XCTAssertEqual(rig.coordinator.credentialRefreshCount, 0)
        XCTAssertEqual(rig.coordinator.renewalCount, 0)
        XCTAssertEqual(rig.coordinator.iceServersForTesting.map(\.urls), before.map(\.urls))
        XCTAssertEqual(rig.coordinator.renewalPlanForTesting?.failures, 1)

        let tooMany = Array(repeating: ICEServerConfiguration(urls: ["turn:relay.example.test:3478"], username: "u", credential: "c"), count: 9)
        rig.signaling.deliver(RelayMessage(type: "renewed", servers: tooMany, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600))
        XCTAssertEqual(rig.coordinator.credentialRefreshCount, 0)
        XCTAssertEqual(rig.coordinator.renewalPlanForTesting?.failures, 2)
        await rig.scheduler.advance(by: 4)
        XCTAssertEqual(rig.signaling.renewals.count, 2)
    }

    func testAServiceSideRefreshFailureKeepsTheLeaseAndTheOldCredentialsAndRetriesSoon() async throws {
        let rig = Rig(isHost: true, serviceResponds: false)
        try await rig.startHost()
        let held = rig.heldRelayUsername
        await rig.scheduler.advance(by: 1200)
        let sent = rig.signaling.renewals.count
        rig.signaling.deliver(RelayMessage(type: "renewed", code: "relay_unavailable", leaseSeconds: 1800, renewAfterSeconds: 30))
        XCTAssertEqual(rig.coordinator.renewalCount, 1)
        XCTAssertEqual(rig.coordinator.credentialRefreshCount, 0)
        XCTAssertEqual(rig.heldRelayUsername, held)
        await rig.scheduler.advance(by: 29)
        XCTAssertEqual(rig.signaling.renewals.count, sent)
        await rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.signaling.renewals.count, sent + 1)
    }

    func testAReconnectStartsRenewalOverWithoutDuplicateTimers() async throws {
        let rig = Rig(isHost: true)
        try await rig.startHost()
        await rig.scheduler.advance(by: 950)
        let beforeLoss = rig.signaling.renewals.count
        XCTAssertGreaterThan(beforeLoss, 0)

        rig.coordinator.simulateTransportLossForTesting()
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        try await waitFor("the retry registered again") { rig.signaling.connects.count == 2 && rig.coordinator.hostRegistered }
        await rig.scheduler.settle()
        XCTAssertNotNil(rig.coordinator.renewalPlanForTesting)

        let atReconnect = rig.signaling.renewals.count
        await rig.scheduler.advance(by: 899)
        XCTAssertEqual(rig.signaling.renewals.count, atReconnect)
        await rig.scheduler.advance(by: 2)
        XCTAssertEqual(rig.signaling.renewals.count, atReconnect + 1, "exactly one renewal is due, not one per past connection")
    }
}
