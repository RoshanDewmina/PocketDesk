import XCTest
import CoreGraphics

final class CouchHostPolicyTests: XCTestCase {
    func test60HzCouchAdmissionNeedsAtMostTenSessionQueriesPerSecond() {
        var cache = CouchSessionSnapshotCache()
        var queries = 0
        for index in 0..<60 {
            let result = cache.snapshot(at: Double(index) / 60) {
                queries += 1
                return [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": false]
            }
            XCTAssertTrue(result.consoleUserActive); XCTAssertFalse(result.screenLocked)
        }
        XCTAssertLessThanOrEqual(queries, 10)
        print("COUCH SESSION: baseline 120 dictionary calls for 60 packets; cached \(queries) shared queries")
    }
    private var activeSession: [String: Any] {
        [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": false]
    }

    func testSessionSnapshotSharesOneQueryUntilItsFreshnessLimit() {
        var cache = CouchSessionSnapshotCache()
        var queries = 0
        let query: () -> [String: Any]? = { queries += 1; return self.activeSession }
        let first = cache.snapshot(at: 10, query: query)
        XCTAssertFalse(first.screenLocked)
        XCTAssertTrue(first.consoleUserActive)
        for offset in [0.0, 0.01, 0.05, 0.099] {
            XCTAssertEqual(cache.snapshot(at: 10 + offset, query: query), first)
        }
        XCTAssertEqual(queries, 1)
        _ = cache.snapshot(at: 10.101, query: query)
        XCTAssertEqual(queries, 2, "lock and console state share a query; stale state is never reused")
        var boundary = CouchSessionSnapshotCache()
        _ = boundary.snapshot(at: 0, query: query)
        _ = boundary.snapshot(at: CouchSessionSnapshotCache.maximumAge, query: query)
        XCTAssertEqual(queries, 4, "the 100 ms boundary is expired")
    }

    func testSessionSnapshotDoesNotReuseAcrossBackwardsOrInvalidTime() {
        var cache = CouchSessionSnapshotCache()
        var queries = 0
        let query: () -> [String: Any]? = { queries += 1; return self.activeSession }
        _ = cache.snapshot(at: 10, query: query)
        _ = cache.snapshot(at: 9, query: query)
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(cache.snapshot(at: .nan, query: query), .unavailable)
        XCTAssertEqual(cache.snapshot(at: .infinity, query: query), .unavailable)
        XCTAssertEqual(queries, 2, "invalid clocks cannot admit input")
        _ = cache.snapshot(at: 9.01, query: query)
        XCTAssertEqual(queries, 3, "an invalid clock also retires the old snapshot")
    }

    func testSessionSnapshotUnavailableAndMissingConsoleStateFailClosed() {
        var cache = CouchSessionSnapshotCache()
        XCTAssertEqual(cache.snapshot(at: 10, query: { nil }), .unavailable)
        let missing = cache.snapshot(at: 11, query: { [:] })
        XCTAssertFalse(missing.consoleUserActive)
        let malformed = cache.snapshot(at: 12, query: { [kCGSessionOnConsoleKey as String: "true"] })
        XCTAssertFalse(malformed.consoleUserActive)
        let malformedLock = cache.snapshot(at: 13, query: {
            [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": "false"]
        })
        XCTAssertTrue(malformedLock.screenLocked)
        let locked = cache.snapshot(at: 14, query: {
            [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true]
        })
        XCTAssertTrue(locked.screenLocked)
    }

    func testSessionSnapshotKillSwitchQueriesEveryTimeAndRetiresCachedState() {
        var cache = CouchSessionSnapshotCache()
        var queries = 0
        let query: () -> [String: Any]? = { queries += 1; return self.activeSession }
        _ = cache.snapshot(at: 10, query: query)
        _ = cache.snapshot(at: 10.01, cacheEnabled: false, query: query)
        _ = cache.snapshot(at: 10.02, cacheEnabled: false, query: query)
        _ = cache.snapshot(at: 10.03, query: query)
        XCTAssertEqual(queries, 4)
    }

    func testSessionNotificationsInvalidateAndLatchDenialUntilMatchingRecovery() {
        let transitions: [(HostSleepPolicy.Event, HostSleepPolicy.Event)] = [(.screenLocked, .screenUnlocked),
            (.sessionResigned, .sessionActivated), (.systemWillSleep, .systemDidWake)]
        for (revoke, recover) in transitions {
            var cache = CouchSessionSnapshotCache()
            var queries = 0
            let query: () -> [String: Any]? = { queries += 1; return self.activeSession }
            _ = cache.snapshot(at: 10, query: query)
            cache.observeAvailability(revoke)
            XCTAssertEqual(cache.snapshot(at: 10.01, query: query), .unavailable)
            XCTAssertEqual(cache.snapshot(at: 11, cacheEnabled: false, query: query), .unavailable)
            XCTAssertEqual(queries, 1, "even a stale healthy OS result cannot undo revocation")
            cache.observeAvailability(recover)
            XCTAssertTrue(cache.snapshot(at: 11.01, query: query).consoleUserActive)
            XCTAssertEqual(queries, 2, "recovery always performs a new query")
        }
    }

    func testSessionRecoveryCannotClearAnotherUnavailableCondition() {
        var cache = CouchSessionSnapshotCache()
        cache.observeAvailability(.screenLocked)
        cache.observeAvailability(.sessionResigned)
        cache.observeAvailability(.screenUnlocked)
        XCTAssertEqual(cache.snapshot(at: 10, query: { self.activeSession }), .unavailable)
        cache.observeAvailability(.sessionActivated)
        XCTAssertTrue(cache.snapshot(at: 10.01, query: { self.activeSession }).consoleUserActive)
        cache.observeAvailability(.displaySlept)
        XCTAssertEqual(cache.snapshot(at: 10.02, query: { nil }), .unavailable,
                       "display notifications also invalidate, without latching a session denial")
    }

    private func enabled(_ session: HostSessionState, capture: Bool, couch: Bool,
                         consent: Bool = true, access: HostPermissionStatus = .granted) -> Bool {
        HostControlPolicy.isEnabled(userConsent: consent, accessibilityPermission: access, session: session,
                                    captureHealthy: capture, couchHealthy: couch)
    }

    func testPictureSessionGateIsExactlyTheOldPolicy() {
        for consent in [false, true] { for access in [HostPermissionStatus.unchecked, .granted, .denied] {
            for capture in [false, true] { for couch in [false, true] {
                XCTAssertEqual(enabled(.picture, capture: capture, couch: couch, consent: consent, access: access),
                               HostControlPolicy.isEnabled(userConsent: consent, accessibilityPermission: access,
                                                           captureHealthy: capture))
            }}
        }}
    }

    func testCouchSessionUsesOnlyCouchHealthAndARefusedSessionNothing() {
        XCTAssertTrue(enabled(.couch, capture: false, couch: true))
        XCTAssertFalse(enabled(.couch, capture: true, couch: false), "a late capture callback must not enable Couch input")
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, consent: false))
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, access: .denied))
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, access: .unchecked))
        for reason in SessionModeRefusal.allCases {
            XCTAssertFalse(enabled(.refused(reason), capture: true, couch: true))
        }
    }

    func testTokensAndWireFields() {
        XCTAssertTrue(HostSessionState.picture.issuesTokens(healthy: false), "Picture keeps today's behaviour")
        XCTAssertTrue(HostSessionState.picture.issuesTokens(healthy: true))
        XCTAssertTrue(HostSessionState.couch.issuesTokens(healthy: true))
        XCTAssertFalse(HostSessionState.couch.issuesTokens(healthy: false))
        XCTAssertFalse(HostSessionState.refused(.notLocal).issuesTokens(healthy: true))
        XCTAssertEqual(HostSessionState.picture.wireMode, "picture")
        XCTAssertEqual(HostSessionState.couch.wireMode, "couch")
        XCTAssertEqual(HostSessionState.refused(.controlOff).wireMode, SessionModeStatus.refused)
        XCTAssertEqual(HostSessionState.refused(.controlOff).wireReason, "controlOff")
        XCTAssertNil(HostSessionState.couch.wireReason)
        XCTAssertNil(HostSessionState.picture.wireReason)
        let refused = HostSessionState.refused(.notLocal)
        XCTAssertNoThrow(try RemoteAction(action: "capture", epoch: 1, mode: refused.wireMode, modeReason: refused.wireReason).validate())
    }

    func testAdmissionRefusesAnythingButAProvenLocalLinkWithControlOn() {
        let ok = CouchAdmissionInputs(routeLocal: true, provenLinkActive: true, allowControl: true, accessibility: .granted)
        XCTAssertNil(CouchAdmission.decide(ok))
        var remote = ok; remote.routeLocal = false
        XCTAssertEqual(CouchAdmission.decide(remote), .notLocal)
        var unproven = ok; unproven.provenLinkActive = false
        XCTAssertEqual(CouchAdmission.decide(unproven), .notLocal)
        var off = ok; off.allowControl = false
        XCTAssertEqual(CouchAdmission.decide(off), .controlOff)
        var noAX = ok; noAX.accessibility = .denied
        XCTAssertEqual(CouchAdmission.decide(noAX), .controlOff)
        var both = off; both.routeLocal = false
        XCTAssertEqual(CouchAdmission.decide(both), .notLocal, "the network reason wins: fixing control would not help")
    }

    func testCouchHealthNeedsEveryTermAndAFreshHeartbeat() {
        let healthy = CouchHealthInputs(routeLocal: true, provenLinkActive: true, heartbeatAge: 0.2, screenLocked: false,
                                        consoleUserActive: true, allowControl: true, accessibility: .granted, phonePaused: false)
        XCTAssertTrue(CouchHealth.isHealthy(healthy))
        var edge = healthy; edge.heartbeatAge = 0.749
        XCTAssertTrue(CouchHealth.isHealthy(edge))
        let breaks: [(inout CouchHealthInputs) -> Void] = [
            { $0.routeLocal = false }, { $0.provenLinkActive = false }, { $0.heartbeatAge = nil },
            { $0.heartbeatAge = 0.75 }, { $0.heartbeatAge = 3 }, { $0.heartbeatAge = -1 },
            { $0.screenLocked = true }, { $0.consoleUserActive = false }, { $0.allowControl = false },
            { $0.accessibility = .denied }, { $0.accessibility = .unchecked }, { $0.phonePaused = true }
        ]
        for (index, mutate) in breaks.enumerated() {
            var inputs = healthy
            mutate(&inputs)
            XCTAssertFalse(CouchHealth.isHealthy(inputs), "term \(index)")
        }
    }

    func testCouchLeaseDropsAHeldButtonOneSecondAfterTheLastRenewal() {
        var lease = RemoteInputLease(duration: RemoteInputLease.couchDuration)
        lease.record(action: "dragDown", accepted: true, at: 10)
        lease.record(action: "holdRenew", accepted: true, at: 10.5)
        XCTAssertFalse(lease.isExpired(at: 11.49))
        XCTAssertTrue(lease.isExpired(at: 11.5))
        XCTAssertEqual(RemoteInputLease().duration, RemoteInputLease.pictureDuration, "Picture keeps its 2 s lease")
    }

    func testChangingTheLeaseDurationNeverExtendsAnArmedDeadline() {
        var armed = RemoteInputLease(duration: RemoteInputLease.pictureDuration)
        armed.record(action: "dragDown", accepted: true, at: 10)
        armed.changeDuration(to: RemoteInputLease.couchDuration, at: 10.5)
        XCTAssertEqual(armed.duration, RemoteInputLease.couchDuration)
        XCTAssertEqual(armed.deadline, 11.5, "Couch shortens a pending Picture deadline")
        armed.changeDuration(to: RemoteInputLease.pictureDuration, at: 11)
        XCTAssertEqual(armed.deadline, 11.5, "Picture never extends a pending Couch deadline")
        XCTAssertTrue(armed.isExpired(at: 11.5))

        var restarted = RemoteInputLease(duration: RemoteInputLease.pictureDuration)
        restarted.record(action: "dragDown", accepted: true, at: 10)
        restarted.changeDuration(to: RemoteInputLease.pictureDuration, at: 11.9)
        XCTAssertEqual(restarted.deadline, 12, "A Picture restart keeps today's deadline exactly")

        var idle = RemoteInputLease(duration: RemoteInputLease.pictureDuration)
        idle.changeDuration(to: RemoteInputLease.couchDuration, at: 5)
        XCTAssertNil(idle.deadline)
        XCTAssertFalse(idle.isExpired(at: 1000))
    }

    func testCouchDisplaysDropMirrorsAndPutTheMainDisplayFirst() {
        let main = HostCouchDisplays.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), mirrorsAnother: false)
        let tv = HostCouchDisplays.Display(id: 2, bounds: CGRect(x: 1470, y: -300, width: 1920, height: 1080), mirrorsAnother: false)
        let mirror = HostCouchDisplays.Display(id: 3, bounds: main.bounds, mirrorsAnother: true)
        let broken = HostCouchDisplays.Display(id: 4, bounds: CGRect(x: 0, y: 0, width: 0, height: 900), mirrorsAnother: false)
        let duplicate = HostCouchDisplays.Display(id: 5, bounds: main.bounds, mirrorsAnother: false)
        let infinite = HostCouchDisplays.Display(id: 6, bounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), mirrorsAnother: false)
        XCTAssertEqual(HostCouchDisplays.rects([tv, mirror, broken, main, duplicate, infinite], main: 1), [main.bounds, tv.bounds])
        XCTAssertEqual(HostCouchDisplays.rects([tv], main: 1), [tv.bounds], "a missing main display keeps the order it was given")
        XCTAssertEqual(HostCouchDisplays.rects([], main: 1), [])
    }
    func testCatalogRefreshDuringCouchNeverEnablesRefreshDuringPictureOrBrowserSharing() {
        XCTAssertTrue(CouchCatalogRefresh.allowed(active: true, session: .couch, browserRunning: false))
        XCTAssertTrue(CouchCatalogRefresh.allowed(active: false, session: .picture, browserRunning: false))
        XCTAssertFalse(CouchCatalogRefresh.allowed(active: true, session: .picture, browserRunning: false))
        XCTAssertFalse(CouchCatalogRefresh.allowed(active: true, session: .refused(.notLocal), browserRunning: false))
        XCTAssertFalse(CouchCatalogRefresh.allowed(active: true, session: .couch, browserRunning: true))
    }

    func testPictureRefreshRejectsLateOrReplacedSessionsAndBackgrounding() {
        let ticket = CouchPictureRefreshTicket(epoch: 7, issuedAt: 10)
        func current(epoch: UInt64 = 7, now: TimeInterval = 11, peer: Bool = true,
                     session: HostSessionState = .couch, connected: Bool = true,
                     active: Bool = true, paused: Bool = false) -> Bool {
            ticket.isCurrent(epoch: epoch, now: now, samePeer: peer, session: session,
                             connected: connected, active: active, paused: paused)
        }
        XCTAssertTrue(current())
        XCTAssertFalse(current(epoch: 8))
        XCTAssertFalse(current(now: 14))
        XCTAssertFalse(current(now: 9))
        XCTAssertFalse(current(peer: false))
        XCTAssertFalse(current(session: .picture))
        XCTAssertFalse(current(connected: false))
        XCTAssertFalse(current(active: false))
        XCTAssertFalse(current(paused: true))
        XCTAssertNotEqual(ticket.id, CouchPictureRefreshTicket(epoch: 7, issuedAt: 10).id)
    }

}
