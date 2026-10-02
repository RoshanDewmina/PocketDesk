import XCTest

final class BigTextProtocolTests: XCTestCase {
    func testDisplayScaleRequestsValidate() {
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 1280).validate())
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 0).validate(),
                         "0 asks for the Mac's own size")
    }

    func testMalformedScaleActionsAreRejected() {
        let invalid: [RemoteAction] = [
            RemoteAction(action: "displayScale", epoch: 3, display: 1),
            RemoteAction(action: "displayScale", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 0, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: .nan),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 25_000),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: -5),
            RemoteAction(action: "displayScale", text: "x", epoch: 3, display: 1, looksLikeWidth: 1280),
            RemoteAction(action: "click", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "capture", epoch: 3, scaleError: "failed"),
            RemoteAction(action: "capture", epoch: 3, scaleError: "nonsense"),
            RemoteAction(action: "displays", epoch: 3, scaleError: String(repeating: "x", count: 65)),
        ]
        for action in invalid { XCTAssertThrowsError(try action.validate(), "\(action.action) must be rejected") }
    }

    func testUnknownScaleErrorOnDisplaysIsAccepted() throws {
        let reply = RemoteAction(action: "displays", epoch: 3, displays: [], display: 1, scaleError: "nonsense")
        XCTAssertNoThrow(try reply.validate(), "a newer Mac's error code must not end the session")
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNil(decoded.scaleError.flatMap(BigTextError.init(rawValue:)))
    }

    func testRequestIdentityRoundTripsOnRequestsAndReplies() throws {
        let id = String(repeating: "a", count: 32)
        for action in [RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 1280, scaleRequestID: id),
                       RemoteAction(action: "displays", epoch: 3, displays: [], display: 1, scaleRequestID: id)] {
            let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action))
            XCTAssertNoThrow(try decoded.validate())
            XCTAssertEqual(decoded.scaleRequestID, id)
        }
    }

    func testInvalidRequestIdentitiesCannotRideOtherActionsOrEarlyReturns() {
        for id in ["", "a", String(repeating: "A", count: 32), String(repeating: "g", count: 32), String(repeating: "0", count: 33)] {
            XCTAssertThrowsError(try RemoteAction(action: "displayScale", display: 1, looksLikeWidth: 1280, scaleRequestID: id).validate())
        }
        let id = String(repeating: "a", count: 32)
        for name in ["heartbeat", "capture", "display", "click"] {
            XCTAssertThrowsError(try RemoteAction(action: name, display: 1, scaleRequestID: id).validate())
        }
    }

    func testDescriptorScaleFields() {
        var display = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
        display.scaleSteps = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)]
        display.scaleBaselineWidth = 1470
        display.scaleCurrentWidth = 1280
        XCTAssertNoThrow(try display.validate())

        display.scaleCurrentWidth = 1111
        XCTAssertThrowsError(try display.validate(), "current must be the baseline or an offered step")
        display.scaleCurrentWidth = nil
        display.scaleSteps = [ScaleStep(width: 1600, height: 1040)]
        XCTAssertThrowsError(try display.validate(), "steps are bigger text, so narrower than the baseline")
        display.scaleSteps = Array(repeating: ScaleStep(width: 1000, height: 650), count: 5)
        XCTAssertThrowsError(try display.validate(), "at most four steps")
        display.scaleSteps = [ScaleStep(width: 1280, height: 832)]
        display.scaleBaselineWidth = nil
        XCTAssertThrowsError(try display.validate(), "steps need a baseline")
        display.scaleSteps = []
        display.scaleBaselineWidth = 1470
        XCTAssertNoThrow(try display.validate(), "already at the largest size offers no steps")
    }

    func testOlderDecodersIgnoreTheNewDescriptorFields() {
        struct OldDescriptor: Decodable { var id: UInt32; var name: String; var width: Double; var height: Double }
        let json = #"{"id":1,"name":"Built-in","width":1470,"height":956,"main":true,"scaleSteps":[{"width":1280,"height":832}],"scaleBaselineWidth":1470}"#
        XCTAssertNoThrow(try JSONDecoder().decode(OldDescriptor.self, from: Data(json.utf8)))
    }

    func testErrorReplyRoundTrips() throws {
        let reply = RemoteAction(action: "displays", epoch: 4, displays: [], display: 1, scaleError: BigTextError.failed.rawValue)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertEqual(decoded.scaleError, "failed")
    }

    func testCapabilityIsOptIn() {
        XCTAssertEqual(SessionFeature.displayScale, "display.scale.2")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.displayScale), "advertised only when the Mac allows it")
    }
}


final class DeliberateEndProtocolTests: XCTestCase {
    func testBareEndActionValidatesAndRejectsInputAndMetadata() throws {
        XCTAssertNoThrow(try RemoteAction(action: "sessionEnd", epoch: 7).validate())
        let malformed = [RemoteAction(action: "sessionEnd", text: "x"),
                         RemoteAction(action: "sessionEnd", key: "a"),
                         RemoteAction(action: "sessionEnd", x: 1),
                         RemoteAction(action: "sessionEnd", modifiers: ["command"]),
                         RemoteAction(action: "sessionEnd", display: 1),
                         RemoteAction(action: "sessionEnd", textFocusEditable: true),
                         RemoteAction(action: "sessionEnd", interaction: NativeInteraction(token: "x"))]
        for action in malformed { XCTAssertThrowsError(try action.validate()) }
    }

    func testBackgroundPauseSurvivesRetiredGeometryOnlyForOptedAuthenticatedLivePeers() {
        func accepts(epochMatches: Bool = false, connected: Bool = true, sharing: Bool = true,
                     refused: Bool = false, ending: Bool = false, opted: Bool = true, enabled: Bool = true) -> Bool {
            DeliberateSessionEnd.allowsBackgroundPause(epochMatches: epochMatches, connected: connected,
                sharing: sharing, sessionRefused: refused, ending: ending,
                peerFeatures: opted ? [SessionFeature.deliberateEnd] : [], enabled: enabled)
        }
        XCTAssertTrue(accepts(), "A Big Text geometry update cannot swallow the authenticated background notice")
        XCTAssertFalse(accepts(opted: false), "Legacy pause retains its geometry requirement")
        XCTAssertFalse(accepts(enabled: false), "Rollback retains the original requirement")
        XCTAssertTrue(accepts(epochMatches: true, opted: false, enabled: false))
        XCTAssertFalse(accepts(connected: false))
        XCTAssertFalse(accepts(sharing: false))
        XCTAssertFalse(accepts(refused: true))
        XCTAssertFalse(accepts(ending: true), "A late pause cannot reopen an ending session")
        XCTAssertFalse(accepts(epochMatches: true, connected: false))
        XCTAssertFalse(accepts(epochMatches: true, ending: true))
    }

    func testForegroundResumeAcceptsOnlyCurrentOrExactAcceptedPauseEpoch() {
        func accepts(requested: UInt64, pausedEpoch: UInt64? = 7, opted: Bool = true,
                     enabled: Bool = true, paused: Bool = true, connected: Bool = true,
                     ending: Bool = false) -> Bool {
            DeliberateSessionEnd.allowsForegroundResume(requestedEpoch: requested, currentEpoch: 8,
                acceptedPauseEpoch: pausedEpoch, paused: paused, connected: connected, sharing: true,
                sessionRefused: false, ending: ending,
                peerFeatures: opted ? [SessionFeature.deliberateEnd] : [], enabled: enabled)
        }
        XCTAssertTrue(accepts(requested: 7), "The foreground can resume from the exact admitted background epoch")
        XCTAssertTrue(accepts(requested: 8))
        XCTAssertFalse(accepts(requested: 6), "An unrelated retired geometry never authorizes resume")
        XCTAssertFalse(accepts(requested: 7, pausedEpoch: nil))
        XCTAssertFalse(accepts(requested: 7, opted: false))
        XCTAssertFalse(accepts(requested: 7, enabled: false))
        XCTAssertTrue(accepts(requested: 8, opted: false, enabled: false))
        XCTAssertFalse(accepts(requested: 7, paused: false))
        XCTAssertFalse(accepts(requested: 7, connected: false))
        XCTAssertFalse(accepts(requested: 7, ending: true))
    }

    func testCombinedEnrollmentAudioAndEndFitHandshakeAndHostAdvertisement() throws {
        let suite = "Batch7Handshake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = MacShareBlocker.Handshake.phoneRequest(
            [SessionFeature.videoRefinement, SessionFeature.textClarity], defaults: defaults)
        let body = try JSONEncoder().encode(request)
        let requested = MacShareBlocker.Handshake.features(in: body)
        XCTAssertEqual(request.features.count, 8)
        XCTAssertEqual(request.options?.count, 4)
        XCTAssertEqual(requested, request.requested, "Neither audio consent nor End can be silently dropped")
        XCTAssertLessThanOrEqual(body.count, 1024)
        let enrollment = PairEnrollment.Request(commitment: Data(repeating: 1, count: 32),
                                                handshake: request, phoneName: "Phone")
        XCTAssertNoThrow(try PairEnrollment.validate(enrollment))
        let advertised = HostFeatureList.features(
            base: SessionFeature.host + [SessionFeature.couch, SessionFeature.deliberateEnd,
                                         SessionFeature.lanWake, SessionFeature.away],
            allowBigText: true, accessibility: true, peerFeatures: requested)
        XCTAssertEqual(advertised.count, 32)
        for feature in [SessionFeature.phoneAudio, SessionFeature.deliberateEnd, SessionFeature.displayScale,
                        SessionFeature.lanWake, SessionFeature.away] {
            XCTAssertTrue(advertised.contains(feature), "The 32-feature cap must retain \(feature)")
        }
        XCTAssertNoThrow(try RemoteAction(action: "capture", epoch: 1, features: advertised).validate())
        let scoped = SharedCaptureScopePolicy.features(advertised, kind: .window)
        XCTAssertFalse(scoped.contains(SessionFeature.phoneAudio))
        XCTAssertFalse(scoped.contains(SessionFeature.deliberateEnd))
    }

    func testHandshakeOptInPreservesFeatureAndOptionBoundsAndRollback() throws {
        let suite = "DeliberateEndProtocolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity], defaults: defaults)
        XCTAssertEqual(request.features.count, 8)
        XCTAssertLessThanOrEqual(request.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions)
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(request)).contains(SessionFeature.deliberateEnd))
        defaults.set(true, forKey: DeliberateSessionEnd.disabledDefaultsKey)
        XCTAssertFalse(MacShareBlocker.Handshake.phoneRequest([], defaults: defaults).requested.contains(SessionFeature.deliberateEnd))
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.deliberateEnd), "The host advertises only to a peer that opted in")
    }
}
