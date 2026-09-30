import XCTest
import CoreGraphics

final class CouchHostPolicyTests: XCTestCase {
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
