import XCTest

final class ClipboardTransferTests: XCTestCase {
    private let transfer = "0123456789abcdef0123456789abcdef"

    private func text(bytes: Int) -> String {
        let unit = "é日🙂a"
        var value = String(repeating: unit, count: bytes / unit.utf8.count)
        while value.utf8.count < bytes { value += "x" }
        return value
    }

    func testAutomaticMarkerIsDataOnlyAndCannotChangeMidTransfer() throws {
        var frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text(bytes: 5000)), operation: "data", transfer: transfer)
        frames = frames.map { var frame = $0; frame.automatic = true; return frame }
        XCTAssertNoThrow(try frames[0].validate())
        var assembler = ClipboardAssembler()
        XCTAssertEqual(assembler.accept(frames[0], at: 1), .progress)
        var mixed = frames[1]; mixed.automatic = nil
        XCTAssertEqual(assembler.accept(mixed, at: 1), .failed(transfer: transfer))
        var push = frames[0]; push.op = "push"
        XCTAssertThrowsError(try push.validate())
        var pull = ClipboardFrame.pull(transfer); pull.automatic = true
        XCTAssertThrowsError(try pull.validate())
        var result = ClipboardFrame.result(transfer, .stored); result.automatic = true
        XCTAssertThrowsError(try result.validate())
    }

    func testClipboardHandshakeOptInPreservesEightFeatureBoundWithRefinement() throws {
        let request = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity])
        XCTAssertLessThanOrEqual(request.features.count, 8)
        XCTAssertLessThanOrEqual(request.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions)
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(request)).contains(SessionFeature.clipboardSync))
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(MacShareBlocker.Handshake(features: [SessionFeature.extendedFeatureList]))).contains(SessionFeature.clipboardSync))
    }

    func testChunkingRoundTripsMultibyteTextSplitAcrossChunkBoundaries() throws {
        let original = text(bytes: 3 * ClipboardLimits.chunkBytes + 17)
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: original), operation: "push", transfer: transfer)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.last?.data?.count, 17)
        for frame in frames { XCTAssertNoThrow(try frame.validate()) }

        var assembler = ClipboardAssembler()
        var outcome = ClipboardAssembler.Outcome.progress
        for frame in frames { outcome = assembler.accept(frame, at: 1) }
        XCTAssertEqual(outcome, .complete(transfer: transfer, payload: ClipboardPayload(text: original, kind: .text)))
        XCTAssertNil(assembler.activeTransfer)
    }

    func testWorstCaseChunkStaysInsideTheControlPacketLimit() throws {
        let session = String(repeating: "S", count: 64)
        for byte: UInt8 in [0xFF, 0x3F, 0x00] {
            let data = Data(repeating: byte, count: ClipboardLimits.chunkBytes)
            let frame = ClipboardFrame(op: "data", transfer: transfer, kind: "text", index: 0,
                                       count: ClipboardLimits.maximumChunks, bytes: ClipboardLimits.maximumBytes,
                                       digest: String(repeating: "f", count: 64), data: data)
            XCTAssertNoThrow(try frame.validate())
            let packet = ControlPacket(session: session, sequence: .max,
                                       action: RemoteAction(action: "clipboard", epoch: .max, clipboard: frame))
            let encoded = try JSONEncoder().encode(packet)
            XCTAssertLessThan(encoded.count, 16_384, "A chunk of byte \(byte) must fit the data channel's message bound")
        }
    }

    func testSizeLimitsAcceptTheMaximumAndRejectEmptyOrOversizedText() throws {
        let maximum = String(repeating: "a", count: ClipboardLimits.maximumBytes)
        XCTAssertEqual(try ClipboardChunker.frames(for: ClipboardPayload(text: maximum), operation: "push", transfer: transfer).count,
                       ClipboardLimits.maximumChunks)
        XCTAssertThrowsError(try ClipboardChunker.frames(for: ClipboardPayload(text: maximum + "a"), operation: "push", transfer: transfer)) {
            XCTAssertEqual($0 as? ClipboardRefusal, .tooLarge)
        }
        XCTAssertThrowsError(try ClipboardChunker.frames(for: ClipboardPayload(text: ""), operation: "push", transfer: transfer)) {
            XCTAssertEqual($0 as? ClipboardRefusal, .empty)
        }
    }

    func testFrameValidationRejectsMalformedFraming() throws {
        let valid = try ClipboardChunker.frames(for: ClipboardPayload(text: text(bytes: 5000)), operation: "push", transfer: transfer)[0]
        XCTAssertNoThrow(try valid.validate())
        var cases: [ClipboardFrame] = []
        var frame = valid; frame.version = 2; cases.append(frame)
        frame = valid; frame.op = "upload"; cases.append(frame)
        frame = valid; frame.transfer = "short"; cases.append(frame)
        frame = valid; frame.transfer = "../../etc/passwd0000"; cases.append(frame)
        frame = valid; frame.kind = "image"; cases.append(frame)
        frame = valid; frame.index = 2; cases.append(frame)
        frame = valid; frame.count = 3; cases.append(frame)
        frame = valid; frame.bytes = ClipboardLimits.maximumBytes + 1; cases.append(frame)
        frame = valid; frame.data = Data(count: 10); cases.append(frame)
        frame = valid; frame.digest = String(repeating: "F", count: 64); cases.append(frame)
        frame = valid; frame.digest = "abc"; cases.append(frame)
        frame = valid; frame.status = "stored"; cases.append(frame)
        frame = valid; frame.afterCopy = true; cases.append(frame)
        var pull = ClipboardFrame.pull(transfer); pull.data = Data([1]); cases.append(pull)
        var result = ClipboardFrame.result(transfer, .stored); result.status = "not ok"; cases.append(result)
        result = ClipboardFrame.result(transfer, .stored); result.data = Data([1]); cases.append(result)
        for (index, invalid) in cases.enumerated() {
            XCTAssertThrowsError(try invalid.validate(), "case \(index) must be rejected")
        }
        XCTAssertNoThrow(try ClipboardFrame.pull(transfer, afterCopy: true).validate())
        XCTAssertNoThrow(try ClipboardFrame.result(transfer, .concealed).validate())
    }

    func testAssemblerDiscardsGapsReorderingTamperingAndInvalidUTF8() throws {
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text(bytes: 9000)), operation: "data", transfer: transfer)
        var assembler = ClipboardAssembler()
        XCTAssertEqual(assembler.accept(frames[1], at: 0), .failed(transfer: transfer), "A transfer must start at chunk 0")

        XCTAssertEqual(assembler.accept(frames[0], at: 0), .progress)
        XCTAssertEqual(assembler.accept(frames[2], at: 0), .failed(transfer: transfer), "A gap discards the transfer")
        XCTAssertNil(assembler.activeTransfer)

        XCTAssertEqual(assembler.accept(frames[0], at: 0), .progress)
        XCTAssertEqual(assembler.accept(frames[0], at: 0), .progress, "A new chunk 0 restarts cleanly")
        XCTAssertEqual(assembler.accept(frames[1], at: 0), .progress)
        var tampered = frames[2]
        tampered.data = Data(repeating: 0x41, count: tampered.data!.count)
        XCTAssertEqual(assembler.accept(tampered, at: 0), .failed(transfer: transfer), "Digest mismatch must not complete")

        let invalidUTF8 = Data([0xC3, 0x28, 0xFF, 0xFE])
        let bad = ClipboardFrame(op: "data", transfer: transfer, kind: "text", index: 0, count: 1, bytes: invalidUTF8.count,
                                 digest: ClipboardDigest.hex(invalidUTF8), data: invalidUTF8)
        XCTAssertEqual(assembler.accept(bad, at: 0), .failed(transfer: transfer), "Only valid UTF-8 text is accepted")

        XCTAssertEqual(assembler.accept(frames[0], at: 10), .progress)
        XCTAssertNil(assembler.expire(at: 14))
        XCTAssertEqual(assembler.expire(at: 15.5), transfer, "A stalled transfer expires")
        XCTAssertNil(assembler.activeTransfer)
    }

    func testOutboxReleasesFramesOnlyWhileTheControlBufferIsLow() throws {
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text(bytes: 5 * ClipboardLimits.chunkBytes)),
                                                 operation: "data", transfer: transfer)
        var outbox = ClipboardOutbox()
        outbox.load(frames)
        XCTAssertEqual(outbox.release(bufferedAmount: nil), [], "A closed channel releases nothing")
        XCTAssertEqual(outbox.release(bufferedAmount: ClipboardLimits.bufferedHighWater), [])
        XCTAssertEqual(outbox.release(bufferedAmount: 0).map(\.index), [0, 1])
        XCTAssertEqual(outbox.release(bufferedAmount: 900).map(\.index), [2, 3])
        XCTAssertEqual(outbox.transfer, transfer)
        XCTAssertEqual(outbox.release(bufferedAmount: 0).map(\.index), [4])
        XCTAssertTrue(outbox.isEmpty)
        outbox.load(frames)
        outbox.cancel()
        XCTAssertEqual(outbox.release(bufferedAmount: 0), [])
    }

    func testPrivacyVerdictHonorsPasswordManagerAndTransientMarkers() {
        let plain = ["public.utf8-plain-text", "public.html"]
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain), .shareable)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["com.apple.is-remote-clipboard"]), .shareable)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["org.nspasteboard.ConcealedType"]), .concealed)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["com.agilebits.onepassword"]), .concealed)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["org.nspasteboard.TransientType"]), .transient)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["de.petermaurer.TransientPasteboardType"]), .transient)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["Pasteboard generator type"]), .transient)
        XCTAssertEqual(ClipboardPrivacy.verdict(forTypes: plain + ["org.nspasteboard.AutoGeneratedType"]), .autoGenerated)
    }

    func testURLClassificationOnlyAppliesToALoneWebAddress() {
        XCTAssertEqual(ClipboardPayload.classify(" https://example.com/a?b=c \n"), .url)
        XCTAssertEqual(ClipboardPayload.classify("see https://example.com"), .text)
        XCTAssertEqual(ClipboardPayload.classify("file:///etc/hosts"), .text)
        XCTAssertEqual(ClipboardPayload.classify("javascript:alert(1)"), .text)
    }
}

final class SessionExtensionProtocolTests: XCTestCase {
    private let transfer = "0123456789abcdef0123456789abcdef"

    /// The pre-extension shape of RemoteAction, standing in for an older installed peer.
    private struct LegacyAction: Codable {
        var action: String
        var x: Double
        var y: Double
        var text: String
        var key: String
        var modifiers: [String]
        var epoch: UInt64
        var streamQuality: StreamQuality?
    }

    func testExtensionActionsValidateOnlyWithTheirOwnPayload() throws {
        XCTAssertNoThrow(try RemoteAction(action: "clipboard", epoch: 3, clipboard: .pull(transfer)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "pause", epoch: 3).validate())
        XCTAssertNoThrow(try RemoteAction(action: "resume", epoch: 3).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, features: SessionFeature.host + [SessionFeature.couch]).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: Array(repeating: "a", count: 32)).validate())

        let invalid = [
            RemoteAction(action: "clipboard", epoch: 3),
            RemoteAction(action: "clipboard", text: "secret", epoch: 3, clipboard: .pull(transfer)),
            RemoteAction(action: "clipboard", key: "v", epoch: 3, clipboard: .pull(transfer)),
            RemoteAction(action: "clipboard", epoch: 3, interaction: NativeInteraction(token: "t"), clipboard: .pull(transfer)),
            RemoteAction(action: "pause", epoch: 3, clipboard: .pull(transfer)),
            RemoteAction(action: "resume", x: 1, epoch: 3),
            RemoteAction(action: "move", clipboard: .pull(transfer)),
            RemoteAction(action: "heartbeat", features: ["pause.1"]),
            RemoteAction(action: "capture", features: ["bad feature"]),
            RemoteAction(action: "capture", features: Array(repeating: "a", count: 33))
        ]
        for (index, action) in invalid.enumerated() {
            XCTAssertThrowsError(try action.validate(), "case \(index) must be rejected")
        }
    }

    func testSessionExtensionsAndPointerTelemetryRejectEachOthersFields() throws {
        let sample = PointerSync(videoCursor: true, x: 10, y: 20, visible: true, shape: "arrow", sample: 1)
        XCTAssertNoThrow(try RemoteAction(action: "pointer", pointerSync: sample).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, pointerSync: PointerSync(videoCursor: true),
                                          features: SessionFeature.host, hostState: "displayAsleep").validate())
        XCTAssertThrowsError(try RemoteAction(action: "pointer", pointerSync: sample, clipboard: .pull(transfer)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "pointer", pointerSync: sample, features: ["pause.1"]).validate())
        XCTAssertThrowsError(try RemoteAction(action: "clipboard", epoch: 3, pointerSync: PointerSync(overlay: true),
                                              clipboard: .pull(transfer)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "pause", epoch: 3, pointerSync: PointerSync(move: 1)).validate())
    }

    func testOlderPeersStillDecodeStatusMessagesThatAdvertiseFeatures() throws {
        let capture = RemoteAction(action: "capture", x: 1, epoch: 7, streamQuality: .sharp, features: SessionFeature.host)
        let legacy = try JSONDecoder().decode(LegacyAction.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(legacy.action, "capture")
        XCTAssertEqual(legacy.epoch, 7)

        let oldHostCapture = Data(#"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":2}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: oldHostCapture)
        XCTAssertNil(decoded.features, "A phone sees no clipboard or pause support from an older host")
        XCTAssertNoThrow(try decoded.validate())
    }

    func testUnknownResultCodesFromNewerPeersDegradeInsteadOfFailingTheSession() throws {
        let future = RemoteAction(action: "clipboard", epoch: 1, clipboard: ClipboardFrame(op: "result", transfer: transfer, status: "quarantined"))
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(future))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNil(decoded.clipboard?.status.flatMap(ClipboardStatus.init(rawValue:)))
    }
}

final class SessionContinuityTests: XCTestCase {
    func testHostPauseReservesTheSessionForAGracePeriod() {
        var pause = HostPhonePause()
        XCTAssertFalse(pause.isExpired(at: 1_000))
        pause.begin(at: 100)
        pause.begin(at: 130)
        XCTAssertTrue(pause.isPaused)
        XCTAssertFalse(pause.isExpired(at: 100 + HostPhonePause.grace - 0.1))
        XCTAssertTrue(pause.isExpired(at: 100 + HostPhonePause.grace), "A repeated pause must not extend the grace period")
        pause.clear()
        XCTAssertFalse(pause.isPaused)
        XCTAssertFalse(pause.isExpired(at: 10_000))
    }

    func testNoSessionMeansNothingToHoldOrResume() {
        var continuity = BackgroundContinuity()
        XCTAssertEqual(continuity.enterBackground(at: 0, sessionOpen: false, canHold: false, budget: 30), .none)
        XCTAssertEqual(continuity.returnToForeground(at: 5, sessionConnected: false), .none)
    }

    func testShortAppSwitchHoldsThenResumesTheLiveSession() {
        var continuity = BackgroundContinuity()
        XCTAssertEqual(continuity.enterBackground(at: 10, sessionOpen: true, canHold: true, budget: 29.5), .hold(seconds: 24.5))
        XCTAssertTrue(continuity.isHolding)
        XCTAssertEqual(continuity.enterBackground(at: 11, sessionOpen: true, canHold: true, budget: 29), .none,
                       "A repeated background event must not restart the hold")
        XCTAssertEqual(continuity.returnToForeground(at: 18, sessionConnected: true), .resumeHeldSession)
        XCTAssertEqual(continuity.phase, .foreground)
    }

    func testHoldIsBoundedByTheSystemBudget() {
        var continuity = BackgroundContinuity()
        XCTAssertEqual(continuity.enterBackground(at: 0, sessionOpen: true, canHold: true, budget: nil),
                       .hold(seconds: BackgroundContinuity.maximumHold))
        continuity.reset()
        XCTAssertEqual(continuity.enterBackground(at: 0, sessionOpen: true, canHold: true, budget: 6), .release,
                       "Too little background time closes the session cleanly instead of risking termination")
        XCTAssertEqual(continuity.returnToForeground(at: 60, sessionConnected: false), .reconnect)
    }

    func testExpiredHoldOrLostTransportReconnectsOnReturn() {
        var continuity = BackgroundContinuity()
        _ = continuity.enterBackground(at: 0, sessionOpen: true, canHold: true, budget: 30)
        XCTAssertTrue(continuity.endHold())
        XCTAssertFalse(continuity.endHold())
        XCTAssertEqual(continuity.returnToForeground(at: 120, sessionConnected: false), .reconnect)

        _ = continuity.enterBackground(at: 200, sessionOpen: true, canHold: true, budget: 30)
        XCTAssertEqual(continuity.returnToForeground(at: 205, sessionConnected: false), .reconnect,
                       "A held session the OS dropped is re-established without re-pairing")
    }

    func testLongAbsenceOffersReconnectInsteadOfResumingAutomatically() {
        var continuity = BackgroundContinuity()
        XCTAssertEqual(continuity.enterBackground(at: 0, sessionOpen: true, canHold: false, budget: 30), .release)
        XCTAssertEqual(continuity.returnToForeground(at: BackgroundContinuity.automaticResumeWindow + 1, sessionConnected: false),
                       .offerReconnect)
    }

    func testLivePiPNeedsNoHeldResumeButItsLossHasABoundedReturnIntent() {
        var continuity = BackgroundContinuity()
        continuity.enterLiveBackground(at: 10, sessionOpen: false)
        XCTAssertEqual(continuity.phase, .foreground)
        continuity.enterLiveBackground(at: 10, sessionOpen: true)
        XCTAssertTrue(continuity.isViewing)
        XCTAssertFalse(continuity.isHolding, "PiP does not acquire the finite background-task hold")
        XCTAssertEqual(continuity.returnToForeground(at: 20, sessionConnected: true), .none)
        continuity.enterLiveBackground(at: 30, sessionOpen: true)
        continuity.enterLiveBackground(at: 40, sessionOpen: true)
        XCTAssertTrue(continuity.endHold())
        XCTAssertFalse(continuity.endHold())
        XCTAssertEqual(continuity.returnToForeground(at: 50, sessionConnected: false), .reconnect)
        XCTAssertEqual(continuity.returnToForeground(at: 51, sessionConnected: false), .none)
        continuity.enterLiveBackground(at: 60, sessionOpen: true)
        continuity.enterLiveBackground(at: 60 + BackgroundContinuity.automaticResumeWindow, sessionOpen: true)
        XCTAssertEqual(continuity.returnToForeground(at: 61 + BackgroundContinuity.automaticResumeWindow, sessionConnected: false), .offerReconnect,
                       "Repeated background callbacks cannot extend the original return limit")
        continuity.enterLiveBackground(at: 1000, sessionOpen: true)
        continuity.reset()
        XCTAssertEqual(continuity.returnToForeground(at: 1001, sessionConnected: false), .none,
                       "Explicit termination invalidates the live-PiP return intent")
    }
}
