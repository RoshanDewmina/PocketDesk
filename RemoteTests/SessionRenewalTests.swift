import XCTest
import Foundation

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
        let rig = RenewalRig(isHost: true)
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal, SignalingFeature.route, "guest-v1", SignalingFeature.devices])
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
        let rig = RenewalRig(isHost: false)
        try await rig.startPhone()
        XCTAssertNil(rig.signaling.connects[0].hostToken)
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal, SignalingFeature.route])
        XCTAssertFalse(rig.signaling.connects[0].features.contains("guest-v1"), "Only the host offers guest creation")
        for minute in 1...125 {
            await rig.scheduler.advance(by: 60)
            let held = try XCTUnwrap(rig.heldRelayUsername)
            XCTAssertTrue(rig.service.isCurrent(username: held), "the phone's credential had expired at minute \(minute)")
        }
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertGreaterThanOrEqual(rig.coordinator.credentialRefreshCount, 5)
    }

    func testAnAppThatDoesNotAskForRenewalSendsNothingNewAndEndsAtTheLeaseThenTheReconnectLogicRecovers() async throws {
        let rig = RenewalRig(isHost: true, advertisesRenewal: false)
        var registeredAtExpiry: Bool?
        var statusAtExpiry: String?
        rig.service.onExpired = { [weak coordinator = rig.coordinator] in
            registeredAtExpiry = coordinator?.hostRegistered
            statusAtExpiry = coordinator?.status
        }
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.route, "guest-v1", SignalingFeature.devices])
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        await rig.scheduler.advance(by: 1799)
        XCTAssertEqual(rig.signaling.connects.count, 1)
        XCTAssertTrue(rig.coordinator.hostRegistered)
        XCTAssertTrue(rig.signaling.renewals.isEmpty)

        await rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.service.leaseExpiries, 1)
        XCTAssertEqual(registeredAtExpiry, false, "the expired connection unregisters before reconnecting")
        XCTAssertTrue(statusAtExpiry?.contains("retrying") == true)

        try await waitFor("the existing bounded reconnect registered the Mac again") {
            rig.signaling.connects.count == 2 && rig.coordinator.hostRegistered
        }
        XCTAssertTrue(rig.signaling.renewals.isEmpty)
    }

    func testAServiceThatDoesNotOfferRenewalIsNeverSentRenew() async throws {
        let rig = RenewalRig(isHost: true, serviceOffersRenewal: false)
        try await rig.startHost()
        XCTAssertEqual(rig.signaling.connects[0].features, [SignalingFeature.renewal, SignalingFeature.route, "guest-v1", SignalingFeature.devices])
        XCTAssertNil(rig.coordinator.renewalPlanForTesting)
        await rig.scheduler.advance(by: 1700)
        XCTAssertTrue(rig.signaling.renewals.isEmpty)
        await rig.scheduler.advance(by: 100)
        XCTAssertEqual(rig.service.leaseExpiries, 1)
    }

    func testASilentServiceIsRetriedWithBackoffAndARepliesResetsTheSchedule() async throws {
        let rig = RenewalRig(isHost: true, serviceResponds: false)
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
        let rig = RenewalRig(isHost: true)
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
        let rig = RenewalRig(isHost: true, serviceResponds: false)
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
        let rig = RenewalRig(isHost: true, serviceResponds: false)
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
        let rig = RenewalRig(isHost: true)
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
