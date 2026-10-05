import XCTest

final class VirtualDisplayRotationPolicyTests: XCTestCase {
    private let session = UUID(), track = UUID()
    private let token = String(repeating: "a", count: 32)
    private func identity(epoch: UInt64 = 7, content: UInt64 = 2, session: UUID? = nil, track: UUID? = nil,
                          host: String = "host", pair: String = "pair") -> VideoPresentationIdentity {
        .init(hostRecordID: host, ownerPairID: pair, sessionID: session ?? self.session, trackID: track ?? self.track,
              contentEpoch: content, geometryEpoch: epoch)
    }
    private func request(token: String? = nil, display: UInt32 = 9, scope: UInt64 = 3) -> VirtualDisplayResizeBegin {
        .init(token: token ?? self.token, display: display, fromEpoch: 7, scopeEpoch: scope, pixelWidth: 2622, pixelHeight: 1206)
    }
    private func frame(_ id: VideoPresentationIdentity? = nil, geometry: UInt64 = 7, scope: UInt64 = 3,
                       width: Int = 1206, height: Int = 2622, at: Double = 10, original: Bool = true) -> RotationPresentedSource {
        .init(identity: id ?? identity(), tagGeometry: geometry, tagScope: scope, pixelWidth: width,
              pixelHeight: height, presentedAt: at, originalSource: original)
    }
    private func started() -> VirtualDisplayRotationPolicy {
        var policy = VirtualDisplayRotationPolicy()
        XCTAssertTrue(policy.start(request(), frame: frame(), current: identity(), scope: 3, display: 9, routeDeadline: 20, now: 10))
        return policy
    }
    func testActualNewTaggedSourceEndsHoldOnlyAfterHostBindsItsRealEpoch() {
        var p = started(); let successor = identity(epoch: 9, content: 3)
        let new = frame(successor, geometry: 9, width: 2622, height: 1206, at: 10.5)
        XCTAssertFalse(p.presented(new, current: successor, scope: 3, display: 9, now: 10.5))
        XCTAssertTrue(p.bind(token: token, epoch: 9, scope: 3, display: 9, current: identity(), now: 10.1))
        XCTAssertTrue(p.permitsPreflight(token: token, epoch: 9, scope: 3, now: 10.2))
        XCTAssertTrue(p.presented(new, current: successor, scope: 3, display: 9, now: 10.5))
        XCTAssertFalse(p.isHolding)
    }
    func testExpiryIsTwoSecondsOrEarlierRouteAndCannotBeRenewedOrReplayed() {
        var p = started(); XCTAssertEqual(p.deadline, 12)
        XCTAssertFalse(p.start(request(token: String(repeating: "b", count: 32)), frame: frame(), current: identity(), scope: 3, display: 9, routeDeadline: 40, now: 11))
        XCTAssertEqual(p.deadline, 12)
        XCTAssertFalse(p.expire(at: 11.999)); XCTAssertTrue(p.expire(at: 12))
        XCTAssertFalse(p.start(request(), frame: frame(at: 12), current: identity(), scope: 3, display: 9, routeDeadline: 40, now: 12))
        var shorter = VirtualDisplayRotationPolicy()
        XCTAssertTrue(shorter.start(request(), frame: frame(), current: identity(), scope: 3, display: 9, routeDeadline: 10.4, now: 10))
        XCTAssertEqual(shorter.deadline, 10.4)
    }
    func testMissingOriginalSourceWrongOldTagIdentityScopeOrDisplayCannotStart() {
        for source in [frame(original: false), frame(geometry: 8), frame(scope: 4), frame(identity(session: UUID())),
                       frame(identity(track: UUID())), frame(identity(pair: "other")), frame(at: 8), frame(at: 11), frame(at: .nan)] {
            var p = VirtualDisplayRotationPolicy()
            XCTAssertFalse(p.start(request(), frame: source, current: identity(), scope: 3, display: 9, routeDeadline: 20, now: 10))
        }
        var p = VirtualDisplayRotationPolicy()
        XCTAssertFalse(p.start(request(display: 10), frame: frame(), current: identity(), scope: 3, display: 9, routeDeadline: 20, now: 10))
        XCTAssertFalse(p.start(request(scope: 4), frame: frame(), current: identity(), scope: 3, display: 9, routeDeadline: 20, now: 10))
    }
    func testWrongTokenScopeOrTrackBindingTerminatesInsteadOfReusingOldAdmission() {
        for (id, scope, display, value) in [(identity(), UInt64(3), UInt32(9), String(repeating: "b", count: 32)),
            (identity(), 4, 9, token), (identity(), 3, 10, token), (identity(track: UUID()), 3, 9, token)] {
            var p = started()
            XCTAssertFalse(p.bind(token: value, epoch: 9, scope: scope, display: display, current: id, now: 10.1))
            XCTAssertFalse(p.isHolding)
        }
    }
    func testOldOrSameSizedWrongTagAndInterpolatedFramesCannotClearHold() {
        var p = started(); let successor = identity(epoch: 9, content: 3)
        XCTAssertTrue(p.bind(token: token, epoch: 9, scope: 3, display: 9, current: identity(), now: 10.1))
        for source in [frame(successor, geometry: 7, width: 2622, height: 1206, at: 10.5),
                       frame(successor, geometry: 9, scope: 4, width: 2622, height: 1206, at: 10.5),
                       frame(successor, geometry: 9, width: 2622, height: 1206, at: 10.5, original: false),
                       frame(successor, geometry: 9, width: 1206, height: 2622, at: 10.5),
                       frame(identity(epoch: 9, content: 3, session: UUID()), geometry: 9, width: 2622, height: 1206, at: 10.5)] {
            XCTAssertFalse(p.presented(source, current: successor, scope: 3, display: 9, now: 10.5))
            XCTAssertTrue(p.isHolding)
        }
        XCTAssertFalse(p.permitsPreflight(token: nil, epoch: 9, scope: 3, now: 10.5))
    }
    func testRetirementAndExpiredPhysicalCallbacksNeverRestorePixels() {
        var p = started(); let successor = identity(epoch: 9, content: 3)
        XCTAssertTrue(p.bind(token: token, epoch: 9, scope: 3, display: 9, current: identity(), now: 10.1))
        let new = frame(successor, geometry: 9, width: 2622, height: 1206, at: 12)
        XCTAssertFalse(p.presented(new, current: successor, scope: 3, display: 9, now: 12))
        p.clear()
        XCTAssertFalse(p.presented(new, current: successor, scope: 3, display: 9, now: 12))
        XCTAssertFalse(p.isHolding)
    }
    func testAbsentCapabilityLeavesWireFieldsAbsentAndMalformedBeginFailsClosed() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteAction(action: "heartbeat"))) as? [String: Any])
        XCTAssertNil(object["virtualDisplayResizeHoldSupported"])
        XCTAssertNil(object["virtualDisplayResizeBegin"])
        XCTAssertNil(object["virtualDisplayResizeToken"])
        var invalid = request(); invalid.version = 2
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try VirtualDisplayResizeBegin(token: "bad", display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 2622, pixelHeight: 1206).validate())
        XCTAssertThrowsError(try VirtualDisplayResizeBegin(token: token, display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 2623, pixelHeight: 1206).validate())
        XCTAssertThrowsError(try VirtualDisplayResizeBegin(token: token, display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: Int.max, pixelHeight: Int.max).validate())
    }
    func testWireExtensionRejectsWrongActionsMixedPayloadsAndMissingToken() throws {
        XCTAssertNoThrow(try RemoteAction(action: "virtualDisplayResizeBegin", epoch: 7, virtualDisplayResizeBegin: request()).validate())
        XCTAssertNoThrow(try RemoteAction(action: "virtualDisplayResizeCancel", epoch: 9, virtualDisplayResizeToken: token).validate())
        XCTAssertNoThrow(try RemoteAction(action: "geometry", x: 1311, y: 603, epoch: 9, virtualDisplayResizeToken: token).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", epoch: 9, virtualDisplayResizeToken: token,
            captureScope: .init(epoch: 3, kind: .display, label: "Entire display", viewOnly: false)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "virtualDisplayResizeBegin", text: "secret", epoch: 7, virtualDisplayResizeBegin: request()).validate())
        XCTAssertThrowsError(try RemoteAction(action: "virtualDisplayResizeBegin", epoch: 7, features: [], virtualDisplayResizeBegin: request()).validate())
        XCTAssertThrowsError(try RemoteAction(action: "virtualDisplayResizeBegin", epoch: 8, virtualDisplayResizeBegin: request()).validate())
        XCTAssertThrowsError(try RemoteAction(action: "virtualDisplayResizeCancel").validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", key: "a", virtualDisplayResizeToken: token).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", x: 1, virtualDisplayResizeToken: token).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", virtualDisplayResizeHoldSupported: true).validate())
    }
}
