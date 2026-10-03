import XCTest
import Foundation
import CoreGraphics

@MainActor
final class MacShareBlockerTests: XCTestCase {
    func testFirst60OptInPreservesEightFeatureBoundAndKillSwitch() throws {
        let suite = "farside.first60.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement], defaults: defaults)
        XCTAssertEqual(request.features.count, 8)
        XCTAssertTrue(MacShareBlocker.Handshake.supportsFirst60(in: try JSONEncoder().encode(request)))
        defaults.set(true, forKey: First60.disabledDefaultsKey)
        let disabled = MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)
        XCTAssertNil(disabled.first60)
        XCTAssertFalse(MacShareBlocker.Handshake.supportsFirst60(in: try JSONEncoder().encode(disabled)))
        XCTAssertFalse(MacShareBlocker.Handshake.supportsFirst60(in: try JSONEncoder().encode(
            MacShareBlocker.Handshake(features: Array(repeating: "f", count: 9), first60: true))))
    }

    func testFirst60StatusCannotClaimPermissionsWhileClosedOrReadyWithoutCaptureGrant() {
        XCTAssertThrowsError(try First60SetupStatus(open: false, permission: .init(stage: .accessibility), mediaReady: true).validate())
        XCTAssertThrowsError(try First60SetupStatus(open: true, permission: .init(stage: .accessibility), mediaReady: false).validate())
        XCTAssertNoThrow(try First60SetupStatus(open: true, permission: .init(stage: .screenRecording), mediaReady: false).validate())
    }

    func testShortcutChipsOptInIsDecodedWithoutGrowingLegacyLists() throws {
        let body = Data(#"{"features":["features.32"],"shortcutChips":true}"#.utf8)
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: body).contains("app.shortcuts.1"))
    }

    private let server = "ws://127.0.0.1:9/signal"

    private struct Sealer {
        let cipher: SignalCipher
        let role: String

        func seal(_ kind: String, request: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(
                ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: role))
        }

        func open(_ message: RelayMessage) throws -> ProtectedMessage {
            try cipher.open(try XCTUnwrap(message.payload), sender: role == "client" ? "host" : "client")
        }
    }

    private func pairedHost(blocker: MacShareBlocker?) throws -> (RemoteCoordinator, ScriptedSignaling, Sealer) {
        let pair = try HostPair.create(server: server, name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        let signaling = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                     registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                     renewalScheduler: ManualScheduler())
        host.allowLegacyPrivateRoute = true
        host.shareBlocker = { blocker }
        host.restore()
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        let phone = Sealer(cipher: try SignalCipher(key: pair.invitation.key, room: pair.invitation.room), role: "client")
        return (host, signaling, phone)
    }

    /// Plays a phone through request, challenge and proof; returns what the Mac sent after the proof.
    private func handshake(_ signaling: ScriptedSignaling, phone: Sealer, features: [String]?, mode: String? = nil) throws -> [ProtectedMessage] {
        let request = try SecureRandom.token()
        let body = try features.map { try JSONEncoder().encode(MacShareBlocker.Handshake(features: $0, mode: mode)) }
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try phone.seal("request", request: request, body: body))
        let challenge = try phone.open(try XCTUnwrap(signaling.sent.last))
        let before = signaling.sent.count
        signaling.deliver(try phone.seal("proof", request: request, session: challenge.session))
        return try signaling.sent.dropFirst(before).filter { $0.type == "signal" }.map(phone.open)
    }

    func testAMacWithoutScreenRecordingTellsAPhoneThatAsksAndKeepsListening() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingOff)
        let replies = try handshake(signaling, phone: phone, features: [MacShareBlocker.feature])
        XCTAssertEqual(replies.map(\.kind), [MacShareBlocker.refusalKind])
        let refusal = try JSONDecoder().decode(MacShareBlocker.Refusal.self, from: try XCTUnwrap(replies.first?.body))
        XCTAssertEqual(refusal.reason, .screenRecordingOff)
        XCTAssertFalse(host.connected)
        XCTAssertTrue(host.hostRegistered, "The Mac stays reachable so the next attempt hears the reason too")
        XCTAssertEqual(host.status, "Ready for your paired phone")
        XCTAssertNil(host.media, "Nothing is streamed")
    }

    func testSealedCouchIntentSkipsOnlyThePictureBlockerBeforeAdmission() throws {
        for blocker in [MacShareBlocker.screenRecordingOff, .screenRecordingApproval] {
            let (host, signaling, phone) = try pairedHost(blocker: blocker)
            let replies = try handshake(signaling, phone: phone, features: MacShareBlocker.Handshake.phone.features,
                                        mode: SessionMode.couch.rawValue)
            XCTAssertEqual(replies.map(\.kind), ["accepted"])
            XCTAssertEqual(host.peerRequestedMode, .couch)
            XCTAssertNil(host.media, "Accepted intent has not completed local proof or media admission")
            XCTAssertFalse(host.connected)
            host.stop()
        }
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingOff)
        let replies = try handshake(signaling, phone: phone, features: MacShareBlocker.Handshake.phone.features,
                                    mode: "unknown")
        XCTAssertEqual(replies.map(\.kind), [MacShareBlocker.refusalKind])
        XCTAssertNil(host.media)
        host.stop()
    }

    func testAnOlderPhoneIsNeitherToldNorAccepted() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingOff)
        let replies = try handshake(signaling, phone: phone, features: nil)
        XCTAssertTrue(replies.isEmpty, "An older phone never receives a message kind it cannot read")
        XCTAssertTrue(host.hostRegistered)
        XCTAssertNil(host.media)
    }

    func testWithoutABlockerTheSessionIsAcceptedAsBefore() throws {
        let (host, signaling, phone) = try pairedHost(blocker: nil)
        let replies = try handshake(signaling, phone: phone, features: [MacShareBlocker.feature])
        XCTAssertEqual(replies.map(\.kind), ["accepted"])
        XCTAssertEqual(host.status, "Connecting live desktop…")
    }

    func testThePhoneAsksAndStopsWithTheMacsReason() async throws {
        let pair = try HostPair.create(server: server, name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                      signaling: signaling, renewalScheduler: ManualScheduler())
        phone.allowLegacyPrivateRoute = true
        phone.restore()
        phone.start()
        signaling.deliver(RelayMessage(type: "registered", role: "client"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let mac = Sealer(cipher: try SignalCipher(key: pair.invitation.key, room: pair.invitation.room), role: "host")
        let request = try mac.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(request.kind, "request")
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: request.body).contains(MacShareBlocker.feature))

        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request.request, session: session))
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
        let body = try JSONEncoder().encode(MacShareBlocker.Refusal(reason: .screenRecordingOff))
        signaling.deliver(try mac.seal(MacShareBlocker.refusalKind, request: request.request, session: session,
                                       sequence: 1, body: body))
        XCTAssertEqual(phone.macBlocker, .screenRecordingOff)
        XCTAssertEqual(phone.status, "Mac unavailable: screenRecordingOff")
        XCTAssertFalse(phone.isRunning, "A missing grant is not retried by itself")
    }

    func testAMacWaitingForApprovalTellsANewPhoneExactlyThat() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingApproval)
        let replies = try handshake(signaling, phone: phone, features: MacShareBlocker.Handshake.phone.features)
        let refusal = try JSONDecoder().decode(MacShareBlocker.Refusal.self, from: try XCTUnwrap(replies.first?.body))
        XCTAssertEqual(refusal.reason, .screenRecordingApproval)
        XCTAssertTrue(host.hostRegistered, "The Mac stays registered while it waits")
        XCTAssertNil(host.media, "Nothing is streamed, and nothing pretends to be")
    }

    func testAPhoneThatOnlyKnowsBlockerOneHearsScreenRecordingOffWhileTheMacWaitsForApproval() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingApproval)
        let replies = try handshake(signaling, phone: phone, features: [MacShareBlocker.feature])
        let refusal = try JSONDecoder().decode(MacShareBlocker.Refusal.self, from: try XCTUnwrap(replies.first?.body))
        XCTAssertEqual(refusal.reason, .screenRecordingOff)
        XCTAssertTrue(host.hostRegistered)
        XCTAssertNil(host.media)
    }

    func testReasonsAreToldOnlyInWordsThePhoneCanRead() {
        let both: Set<String> = [MacShareBlocker.feature, MacShareBlocker.approvalFeature]
        XCTAssertEqual(MacShareBlocker.screenRecordingApproval.told(to: both), .screenRecordingApproval)
        XCTAssertEqual(MacShareBlocker.screenRecordingApproval.told(to: [MacShareBlocker.feature]), .screenRecordingOff,
                       "refuseSession sends this: a blocker.1 phone cannot decode the new reason")
        XCTAssertNil(MacShareBlocker.screenRecordingApproval.told(to: []))
        XCTAssertEqual(MacShareBlocker.screenRecordingOff.told(to: [MacShareBlocker.feature]), .screenRecordingOff)
        XCTAssertNil(MacShareBlocker.screenRecordingOff.told(to: ["other"]))
        XCTAssertEqual(MacShareBlocker.current(screenRecordingGranted: false, captureApprovalPending: true), .screenRecordingOff)
        XCTAssertEqual(MacShareBlocker.current(screenRecordingGranted: true, captureApprovalPending: true), .screenRecordingApproval)
        XCTAssertNil(MacShareBlocker.current(screenRecordingGranted: true, captureApprovalPending: false))
        XCTAssertTrue(ClipboardFrame.isWellFormedStatus(MacShareBlocker.screenRecordingApproval.rawValue),
                      "The reason fits hostState's validation")
    }

    func testApprovalRidesHostStateOnlyForPhonesThatAskAndPresenceStillWins() {
        XCTAssertEqual(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true, controlAllowed: true,
                                                    accessibilityGranted: false, captureApprovalPending: true,
                                                    phoneUnderstandsApproval: true), "screenRecordingApproval")
        XCTAssertEqual(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true, controlAllowed: true,
                                                    accessibilityGranted: false, captureApprovalPending: true,
                                                    phoneUnderstandsApproval: false), "accessibilityOff")
        XCTAssertEqual(MacShareBlocker.sessionState(presence: .locked, phoneUnderstands: true, controlAllowed: true,
                                                    accessibilityGranted: true, captureApprovalPending: true,
                                                    phoneUnderstandsApproval: true), "locked")
    }

    func testTheMacListensWhileWaitingForApprovalButNeverStartsSharing() {
        XCTAssertTrue(MacShareBlocker.shouldListenWithoutSharing(
            wantsSharing: true, suppressed: false, sharingActive: false, listening: false, otherAccessRunning: false,
            screenRecordingGranted: true, captureApprovalPending: true, hasPairedPhone: true, serviceConfigured: true))
        XCTAssertFalse(MacShareBlocker.shouldListenWithoutSharing(
            wantsSharing: true, suppressed: false, sharingActive: false, listening: false, otherAccessRunning: false,
            screenRecordingGranted: true, captureApprovalPending: false, hasPairedPhone: true, serviceConfigured: true))
    }

    func testHandshakeFeaturesAreBounded() throws {
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: nil), [])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: Data("not json".utf8)), [])
        let many = try JSONEncoder().encode(MacShareBlocker.Handshake(features: (0..<9).map { "f\($0)" }))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: many), [])
        let odd = try JSONEncoder().encode(MacShareBlocker.Handshake(features: ["", String(repeating: "a", count: 33), "blocker.1"]))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: odd), ["blocker.1"])
    }

    func testTheMacsOwnPresenceWinsAndAccessibilityIsToldOnlyToPhonesThatAsk() {
        XCTAssertEqual(MacShareBlocker.sessionState(presence: .displayAsleep, phoneUnderstands: true,
                                                    controlAllowed: true, accessibilityGranted: false), "displayAsleep")
        XCTAssertEqual(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                    controlAllowed: true, accessibilityGranted: false), "accessibilityOff")
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: false,
                                                  controlAllowed: true, accessibilityGranted: false))
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                  controlAllowed: false, accessibilityGranted: false),
                     "Control turned off on purpose is not a missing grant")
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                  controlAllowed: true, accessibilityGranted: true))
        XCTAssertTrue(ClipboardFrame.isWellFormedStatus(MacShareBlocker.screenRecordingOff.rawValue))
        XCTAssertTrue(ClipboardFrame.isWellFormedStatus(MacShareBlocker.accessibilityOff.rawValue))
    }

    func testTheMacListensWithoutSharingOnlyWhenScreenRecordingIsTheOnlyThingMissing() {
        func listen(wants: Bool = true, suppressed: Bool = false, active: Bool = false, listening: Bool = false,
                    other: Bool = false, screen: Bool = false, paired: Bool = true, service: Bool = true) -> Bool {
            MacShareBlocker.shouldListenWithoutSharing(wantsSharing: wants, suppressed: suppressed, sharingActive: active,
                                                       listening: listening, otherAccessRunning: other,
                                                       screenRecordingGranted: screen, hasPairedPhone: paired,
                                                       serviceConfigured: service)
        }
        XCTAssertTrue(listen())
        XCTAssertFalse(listen(screen: true), "With the grant, sharing starts normally instead")
        XCTAssertFalse(listen(wants: false), "Stop Sharing means not reachable at all")
        XCTAssertFalse(listen(suppressed: true))
        XCTAssertFalse(listen(active: true))
        XCTAssertFalse(listen(listening: true))
        XCTAssertFalse(listen(other: true))
        XCTAssertFalse(listen(paired: false))
        XCTAssertFalse(listen(service: false))
    }
}

final class ShortcutChipsProtocolTests: XCTestCase {
    func testDefaultsAndBothOlderPeerDirectionsAreInert() throws {
        let suite = "shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ShortcutChips.isEnabled(defaults))
        let on = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity], defaults: defaults)
        XCTAssertEqual(on.features.count, 8)
        XCTAssertEqual(on.options?.count, 4)
        XCTAssertTrue(on.requested.contains(SessionFeature.shortcutChips))
        let decoded = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(on))
        XCTAssertTrue(decoded.contains(SessionFeature.shortcutChips))
        struct OldRequest: Decodable { let features: [String]; let options: [String]? }
        let old = try JSONDecoder().decode(OldRequest.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(old.features, on.features)
        XCTAssertEqual(old.options, on.options)
        XCTAssertFalse(ShortcutChips.negotiated(enabled: true, peerFeatures: Set(old.features + (old.options ?? []))))
        XCTAssertFalse(ShortcutChips.negotiated(enabled: true, peerFeatures: []))
        defaults.set(false, forKey: ShortcutChips.defaultsKey)
        XCTAssertFalse(ShortcutChips.isEnabled(defaults))
        let off = MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)
        XCTAssertNil(off.shortcutChips)
        XCTAssertFalse(off.requested.contains(SessionFeature.shortcutChips))
        XCTAssertFalse(ShortcutChips.negotiated(enabled: false, peerFeatures: [SessionFeature.shortcutChips]))
        let overflow = MacShareBlocker.Handshake(features: Array(repeating: "f", count: 9), shortcutChips: true)
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(overflow)), [])
    }

    func testPublisherDebouncesChangesDoesNotSendSecureAndRetriesOnlyUndelivered() {
        let chrome = FrontmostApp(bundleID: "com.google.Chrome", displayName: "Chrome")
        let safari = FrontmostApp(bundleID: "com.apple.Safari", displayName: "Safari")
        var publisher = FrontmostAppPublication()
        publisher.observe(chrome, at: 10, allowed: true)
        XCTAssertNil(publisher.pending(at: 10.24, secure: false))
        XCTAssertNil(publisher.pending(at: 11, secure: true))
        XCTAssertEqual(publisher.pending(at: 11, secure: false), chrome)
        publisher.delivered(chrome)
        publisher.observe(chrome, at: 12, allowed: true)
        XCTAssertNil(publisher.pending(at: 12, secure: false))
        publisher.observe(safari, at: 13, allowed: true)
        publisher.observe(chrome, at: 13.1, allowed: true)
        XCTAssertNil(publisher.pending(at: 14, secure: false), "Transient app switches emit nothing")
        publisher.observe(safari, at: 15, allowed: true)
        XCTAssertEqual(publisher.pending(at: 15.25, secure: false), safari)
        publisher.delivered(safari)
        let unknown = FrontmostApp(bundleID: nil, displayName: nil)
        publisher.observe(unknown, at: 15.5, allowed: true)
        XCTAssertEqual(publisher.pending(at: 15.75, secure: false), unknown, "Unavailable identity resets to generic")
        publisher.observe(safari, at: 16, allowed: false)
        XCTAssertNil(publisher.pending(at: 17, secure: false))
        publisher.observe(safari, at: 18, allowed: true)
        XCTAssertEqual(publisher.pending(at: 18.25, secure: false), safari, "A new session resends current identity")
    }

    func testAppFrameIsBoundedMetadataOnlyAndWrongActionRejected() throws {
        let app = FrontmostApp(bundleID: "com.google.Chrome", displayName: "Google Chrome")
        XCTAssertNoThrow(try FrontmostApp(bundleID: nil, displayName: nil).validate())
        let update = RemoteAction(action: "heartbeat", epoch: 7, frontmostApp: app)
        try update.validate()
        XCTAssertEqual(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(update)).frontmostApp, app)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["bundleID", "displayName"])
        for kind in ["key", "capture", "clipboard", "wakeRequest", "sessionEnd"] {
            XCTAssertThrowsError(try RemoteAction(action: kind, frontmostApp: app).validate())
        }
        for bad in [FrontmostApp(bundleID: "", displayName: "Chrome"),
                    FrontmostApp(bundleID: "com.bad/app", displayName: "Bad"),
                    FrontmostApp(bundleID: "com.app", displayName: String(repeating: "x", count: 129)),
                    FrontmostApp(bundleID: "com.app", displayName: "Bad\nname")] {
            XCTAssertThrowsError(try bad.validate())
        }
    }

    func testAChipUsesExactlyOneKeyDownAndUpWithChordFlags() throws {
        let chip = ShortcutChip(label: "Reopen tab", key: "t", modifiers: ["command", "shift"])
        var chords: [(CGKeyCode, CGEventFlags)] = []
        let sink = RemoteInputEventSink(pointerLocation: { .zero }, mouseSequence: { _ in true },
            scroll: { _, _, _ in true }, text: { _ in true },
            key: { code, flags in chords.append((code, flags)); return true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: chip.key, modifiers: chip.modifiers)).accepted)
        XCTAssertEqual(chords.count, 1)
        let chord = try XCTUnwrap(chords.first)
        let events = try XCTUnwrap(RemoteInputEventSink.makeKeyEvents(key: chord.0, flags: chord.1))
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.flags == [.maskCommand, .maskShift] })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.0) })
        XCTAssertFalse(driver.held)
    }

    func testHostAdvertisementRetainsBoundsAndDoesNotTellOldPhones() {
        let peer: Set<String> = [SessionFeature.extendedFeatureList, SessionFeature.shortcutChips, SessionFeature.causalInput]
        let existing = HostFeatureList.features(base: SessionFeature.host, allowBigText: true, accessibility: true,
            peerFeatures: peer)
        let modern = ShortcutChips.advertised(addingTo: existing, enabled: true, peerFeatures: peer)
        XCTAssertEqual(modern, existing + [SessionFeature.shortcutChips])
        XCTAssertLessThanOrEqual(modern.count, 32)
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: modern).validate())
        let full = HostFeatureList.features(base: SessionFeature.host + [SessionFeature.couch, SessionFeature.deliberateEnd, SessionFeature.lanWake, SessionFeature.away],
            allowBigText: true, accessibility: true, peerFeatures: peer)
        XCTAssertEqual(full.count, 32)
        XCTAssertEqual(ShortcutChips.advertised(addingTo: full, enabled: true, peerFeatures: peer), full,
            "All previous capabilities survive saturation; chips remain unnegotiated")
        XCTAssertEqual(ShortcutChips.advertised(addingTo: existing, enabled: false, peerFeatures: peer), existing)
        let old = HostFeatureList.features(base: SessionFeature.host, allowBigText: true, accessibility: true, peerFeatures: [])
        XCTAssertLessThanOrEqual(old.count, 16)
        XCTAssertEqual(ShortcutChips.advertised(addingTo: old, enabled: true, peerFeatures: []), old)
    }
}
