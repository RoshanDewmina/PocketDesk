import XCTest

final class CouchPhoneGateTests: XCTestCase {
    /// The phone's gate before Couch mode, copied from `PhoneRemoteModel.canControl` at a65e864.
    private func oldPictureGate(_ i: PhoneControlGate.Inputs) -> Bool {
        !i.privacyShield && !i.contentConcealed && i.connected && i.controlAllowed && i.fresh && i.captureHealthy
            && i.geometryEpoch > 0 && (!i.nativeInteractionSupported || (i.hasToken && i.tokenAge < 1))
    }

    func testPictureGateIsExactlyTheOldExpressionForEveryInput() {
        let flags = [false, true]
        var checked = 0
        for shield in flags { for concealed in flags { for connected in flags { for allowed in flags {
        for fresh in flags { for healthy in flags { for native in flags { for token in flags { for hostCouch in flags {
            for epoch: UInt64 in [0, 3] { for tokenAge in [-0.5, 0.2, 1.0, 5.0] { for statusAge in [0.1, 3.0] {
                let inputs = PhoneControlGate.Inputs(
                    mode: .picture, privacyShield: shield, contentConcealed: concealed, connected: connected,
                    controlAllowed: allowed, fresh: fresh, captureHealthy: healthy, hostModeIsCouch: hostCouch,
                    statusAge: statusAge, geometryEpoch: epoch, nativeInteractionSupported: native,
                    hasToken: token, tokenAge: tokenAge)
                XCTAssertEqual(PhoneControlGate.canControl(inputs), oldPictureGate(inputs), "\(inputs)")
                checked += 1
            }}}
        }}}}}}}}}
        XCTAssertEqual(checked, 512 * 16)
    }

    private let liveCouch = PhoneControlGate.Inputs(
        mode: .couch, connected: true, controlAllowed: true, fresh: false, captureHealthy: true, hostModeIsCouch: true,
        statusAge: 0.3, geometryEpoch: 2, nativeInteractionSupported: true, hasToken: true, tokenAge: 0.3)

    func testCouchNeedsNoPictureButEveryOtherTerm() {
        XCTAssertTrue(PhoneControlGate.canControl(liveCouch))
        let breaks: [(inout PhoneControlGate.Inputs) -> Void] = [
            { $0.connected = false }, { $0.controlAllowed = false }, { $0.captureHealthy = false },
            { $0.hostModeIsCouch = false }, { $0.statusAge = 1.0 }, { $0.statusAge = .infinity }, { $0.statusAge = -0.5 },
            { $0.geometryEpoch = 0 }, { $0.nativeInteractionSupported = false }, { $0.hasToken = false },
            { $0.tokenAge = 1.0 }, { $0.tokenAge = -0.5 }, { $0.privacyShield = true }, { $0.contentConcealed = true }
        ]
        for (index, mutate) in breaks.enumerated() {
            var inputs = liveCouch
            mutate(&inputs)
            XCTAssertFalse(PhoneControlGate.canControl(inputs), "term \(index)")
        }
    }

    func testAMoveUnacknowledgedFor300msStallsUntilTheMacCatchesUp() {
        var dog = CouchAckWatchdog()
        XCTAssertFalse(dog.stalled(at: 0))
        dog.sent(ordinal: 1, at: 10.0)
        dog.sent(ordinal: 2, at: 10.1)
        XCTAssertFalse(dog.stalled(at: 10.29))
        XCTAssertTrue(dog.stalled(at: 10.31))
        dog.acknowledged(through: 1)
        XCTAssertFalse(dog.stalled(at: 10.39), "ordinal 2 was sent at 10.1")
        XCTAssertTrue(dog.stalled(at: 10.41))
        dog.acknowledged(through: 2)
        XCTAssertFalse(dog.stalled(at: 99))
        XCTAssertEqual(dog.pendingCount, 0)
    }

    func testOldAcksAndResetAreHarmless() {
        var dog = CouchAckWatchdog()
        dog.sent(ordinal: 5, at: 1)
        dog.acknowledged(through: 4)
        XCTAssertTrue(dog.stalled(at: 1.5))
        dog.reset()
        XCTAssertFalse(dog.stalled(at: 1.5))
    }

    func testTheQueueIsBoundedButKeepsTheOldestMove() {
        var dog = CouchAckWatchdog()
        for n in 1...1000 { dog.sent(ordinal: UInt64(n), at: Double(n) * 0.001) }
        XCTAssertLessThanOrEqual(dog.pendingCount, CouchAckWatchdog.capacity)
        XCTAssertTrue(dog.stalled(at: 0.302), "the first move, sent at 1 ms, is still the oldest")
    }

    func testModeResolution() {
        let couchMac = Set(SessionFeature.host + [SessionFeature.couch])
        let oldMac = Set(SessionFeature.host)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: oldMac, statusMode: nil, reason: nil), .couchUnsupported)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: oldMac, statusMode: "couch", reason: nil), .couchUnsupported,
                       "Couch without couch.1 is never trusted")
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .picture, features: oldMac, statusMode: nil, reason: nil), .picture)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "couch", reason: nil), .couch)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .picture, features: couchMac, statusMode: "couch", reason: nil), .couch,
                       "a switch inside the session follows the Mac")
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "picture", reason: nil), .picture)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "refused", reason: "controlOff"),
                       .refused(.controlOff))
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "refused", reason: "future"),
                       .refused(.notLocal))
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "somethingNew", reason: nil), .picture)
    }
}
