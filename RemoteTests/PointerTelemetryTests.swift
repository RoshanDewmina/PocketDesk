import XCTest
import AppKit
import CoreGraphics

final class PointerTelemetryEncodingTests: XCTestCase {
    private func roundTrip(_ action: RemoteAction) throws -> RemoteAction {
        let packet = ControlPacket(session: "session", sequence: 7, action: action)
        let data = try JSONEncoder().encode(packet)
        return try JSONDecoder().decode(ControlPacket.self, from: data).action
    }

    func testPointerSampleRoundTripsAndStaysSmall() throws {
        let sync = PointerSync(videoCursor: false, x: 812.5, y: 40.015625, visible: true,
                               shape: PointerShape.iBeam.rawValue, applied: 42, sample: 9)
        let action = RemoteAction(action: "pointer", epoch: 3, pointerSync: sync)
        XCTAssertNoThrow(try action.validate())
        let decoded = try roundTrip(action)
        XCTAssertEqual(decoded.pointerSync, sync)
        XCTAssertNoThrow(try decoded.validate())
        let bytes = try JSONEncoder().encode(ControlPacket(session: String(repeating: "a", count: 64), sequence: 1, action: action))
        XCTAssertLessThan(bytes.count, 400, "Sixty samples a second must stay a trivial fraction of the video")
    }

    func testEachDirectionAcceptsOnlyItsOwnFields() {
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", pointerSync: PointerSync(overlay: true)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", pointerSync: PointerSync(overlay: false),
                                          streamQuality: .sharp).validate())
        XCTAssertNoThrow(try RemoteAction(action: "move", x: 1.5, y: -2, pointerSync: PointerSync(move: 1)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, pointerLocatorSupported: true,
                                          pointerSync: PointerSync(videoCursor: true)).validate())

        let invalid: [RemoteAction] = [
            RemoteAction(action: "heartbeat", pointerSync: PointerSync()),
            RemoteAction(action: "heartbeat", pointerSync: PointerSync(overlay: true, move: 2)),
            RemoteAction(action: "move", pointerSync: PointerSync(move: 0)),
            RemoteAction(action: "move", pointerSync: PointerSync(move: 1, x: 2)),
            RemoteAction(action: "capture", pointerSync: PointerSync()),
            RemoteAction(action: "capture", pointerSync: PointerSync(overlay: true, videoCursor: true)),
            RemoteAction(action: "click", pointerSync: PointerSync(move: 1)),
            RemoteAction(action: "pointer"),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: 1, y: 1, visible: true, shape: "arrow")),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: .nan, y: 1, visible: true, shape: "arrow", sample: 1)),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: 20001, y: 1, visible: true, shape: "arrow", sample: 1)),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: 1, y: 1, visible: true, shape: "arrow<script>", sample: 1)),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: 1, y: 1, visible: true,
                                                                     shape: String(repeating: "a", count: 33), sample: 1)),
            RemoteAction(action: "pointer", pointerSync: PointerSync(version: 2, videoCursor: false, x: 1, y: 1,
                                                                     visible: true, shape: "arrow", sample: 1)),
            RemoteAction(action: "pointer", text: "payload", pointerSync: PointerSync(videoCursor: false, x: 1, y: 1,
                                                                                      visible: true, shape: "arrow", sample: 1)),
            RemoteAction(action: "pointer", x: 5, pointerSync: PointerSync(videoCursor: false, x: 1, y: 1,
                                                                           visible: true, shape: "arrow", sample: 1)),
            RemoteAction(action: "pointer", pointerSync: PointerSync(videoCursor: false, x: 1, y: 1, visible: true,
                                                                     shape: "arrow", sample: 1),
                         textFocusProbe: String(repeating: "a", count: 32), textFocusEditable: true)
        ]
        for action in invalid {
            XCTAssertThrowsError(try action.validate(), "\(action.action) \(String(describing: action.pointerSync))")
        }
    }

    func testLegacyMessagesStillValidateAndUnknownShapesDegradeToArrowArtwork() throws {
        let legacyCapture = Data(#"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":2,"pointerLocatorSupported":true}"#.utf8)
        let capture = try JSONDecoder().decode(RemoteAction.self, from: legacyCapture)
        XCTAssertNil(capture.pointerSync)
        XCTAssertNoThrow(try capture.validate())

        let future = Data(#"{"action":"pointer","x":0,"y":0,"text":"","key":"","modifiers":[],"epoch":2,"pointerSync":{"version":1,"videoCursor":false,"x":4,"y":5,"visible":true,"shape":"spinningWait","sample":3,"futureField":true}}"#.utf8)
        let pointer = try JSONDecoder().decode(RemoteAction.self, from: future)
        XCTAssertNoThrow(try pointer.validate(), "Unknown keys and shape names must not end a session")
        XCTAssertEqual(PointerShape(wire: pointer.pointerSync?.shape), .unknown)
        XCTAssertEqual(PointerGlyph.glyph(for: .unknown).bounds, PointerGlyph.glyph(for: .arrow).bounds)
    }

    func testCaptureEnvelopeIsInvisibleToALegacyDecoder() throws {
        struct LegacyAction: Codable { var action: String; var x: Double; var epoch: UInt64; var pointerLocatorSupported: Bool? }
        let modern = RemoteAction(action: "capture", x: 1, epoch: 4, pointerLocatorSupported: true,
                                  pointerSync: PointerSync(videoCursor: true))
        let legacy = try JSONDecoder().decode(LegacyAction.self, from: JSONEncoder().encode(modern))
        XCTAssertEqual(legacy.action, "capture")
        XCTAssertEqual(legacy.pointerLocatorSupported, true)
    }
}

final class PointerNegotiationTests: XCTestCase {
    func testHostStreamsOnlyToAnAdvertisingPhoneAndHidesOnlyAfterSamplesAndRequest() {
        var host = HostPointerTelemetryPolicy()
        XCTAssertNil(host.sample(observed: CGPoint(x: 1, y: 1), shape: .arrow, videoCursor: true, at: 0),
                     "A legacy phone never receives the pointer action")
        XCTAssertFalse(host.wantsCursorHidden(at: 0))

        host.phoneHeartbeat(PointerSync(overlay: false), at: 1)
        XCTAssertTrue(host.streaming(at: 1.5))
        XCTAssertFalse(host.wantsCursorHidden(at: 1.5), "The phone has not asked for an overlay yet")
        host.phoneHeartbeat(PointerSync(overlay: true), at: 1.6)
        XCTAssertFalse(host.wantsCursorHidden(at: 1.6), "No sample has been sent yet")
        XCTAssertNotNil(host.sample(observed: CGPoint(x: 1, y: 1), shape: .arrow, videoCursor: true, at: 1.61))
        XCTAssertTrue(host.wantsCursorHidden(at: 1.62))

        XCTAssertFalse(host.wantsCursorHidden(at: 2.61), "Capability expires without heartbeats")
        XCTAssertNil(host.sample(observed: CGPoint(x: 2, y: 2), shape: .arrow, videoCursor: false, at: 2.61))

        host.phoneHeartbeat(PointerSync(overlay: true), at: 3)
        XCTAssertTrue(host.wantsCursorHidden(at: 3))
        host.phoneHeartbeat(nil, at: 3.1)
        XCTAssertFalse(host.wantsCursorHidden(at: 3.1), "A heartbeat without the envelope withdraws capability")
    }

    func testOnlyARegularHeartbeatStatesPointerCapability() {
        XCTAssertTrue(RemoteAction(action: "heartbeat", epoch: 1, pointerSync: PointerSync(overlay: true)).isRegularPhoneHeartbeat)
        XCTAssertTrue(RemoteAction(action: "heartbeat", epoch: 1).isRegularPhoneHeartbeat,
                      "A legacy phone's plain heartbeat still withdraws capability")
        let feedback = RemoteAction(action: "heartbeat", epoch: 1,
                                    videoFeedback: VideoFeedback(operation: .refresh, generation: "g", nonce: "n", token: nil, scopeEpoch: 1))
        XCTAssertFalse(feedback.isRegularPhoneHeartbeat, "An LTR ack or refresh request says nothing about the pointer")
        XCTAssertFalse(RemoteAction(action: "heartbeat", epoch: 1, pointerProbe: "p").isRegularPhoneHeartbeat)
        XCTAssertFalse(RemoteAction(action: "heartbeat", epoch: 1, textFocusProbe: String(repeating: "a", count: 32)).isRegularPhoneHeartbeat)
        XCTAssertFalse(RemoteAction(action: "move", epoch: 1).isRegularPhoneHeartbeat)
        XCTAssertTrue(ViewportCapturePolicy.describesViewport(RemoteAction(action: "heartbeat", epoch: 1)))
        XCTAssertFalse(ViewportCapturePolicy.describesViewport(feedback), "The viewport path shares the predicate")
    }

    func testFeedbackHeartbeatsNoLongerFlipTheCapturedCursor() {
        // The 1 Oct loop: regular heartbeats every 0.25 s, an LTR ack or refresh every 2.25 s.
        var host = HostPointerTelemetryPolicy()
        let feedback = RemoteAction(action: "heartbeat", epoch: 1,
                                    videoFeedback: VideoFeedback(operation: .refresh, generation: "g", nonce: "n", token: nil, scopeEpoch: 1))
        let regular = RemoteAction(action: "heartbeat", epoch: 1, pointerSync: PointerSync(overlay: true))
        var messages: [(TimeInterval, RemoteAction)] = stride(from: 0.0, through: 10, by: 0.25).map { ($0, regular) }
        messages += stride(from: 0.3, through: 10, by: 2.25).map { ($0, feedback) }
        messages.sort { $0.0 < $1.0 }
        var hiddenSince: TimeInterval?
        for (time, message) in messages {
            if message.isRegularPhoneHeartbeat { host.phoneHeartbeat(message.pointerSync, at: time) }
            _ = host.sample(observed: CGPoint(x: 1, y: 1), shape: .arrow, videoCursor: hiddenSince == nil, at: time)
            let hidden = host.wantsCursorHidden(at: time + 0.01)
            if hidden, hiddenSince == nil { hiddenSince = time }
            if let since = hiddenSince { XCTAssertTrue(hidden, "The cursor came back at \(time) s after hiding at \(since) s") }
        }
        XCTAssertNotNil(hiddenSince)
        XCTAssertLessThan(hiddenSince ?? 99, 0.5, "The cursor is hidden as soon as the first sample went out")
    }

    func testTheHostKeyKeepsTheCapturedCursorForTheWholeSession() {
        var host = HostPointerTelemetryPolicy(hidesCapturedCursor: false)
        host.phoneHeartbeat(PointerSync(overlay: true), at: 0)
        XCTAssertNotNil(host.sample(observed: .zero, shape: .arrow, videoCursor: true, at: 0.01), "Telemetry still streams")
        XCTAssertFalse(host.wantsCursorHidden(at: 0.1), "With the key off the video keeps the Mac's cursor, so the phone never draws one")
        host.reset()
        host.phoneHeartbeat(PointerSync(overlay: true), at: 1)
        _ = host.sample(observed: .zero, shape: .arrow, videoCursor: true, at: 1.01)
        XCTAssertFalse(host.wantsCursorHidden(at: 1.1), "A reset keeps the switch")
    }

    func testFallbackCooldownPreventsCaptureChurn() {
        var host = HostPointerTelemetryPolicy()
        host.phoneHeartbeat(PointerSync(overlay: true), at: 0)
        _ = host.sample(observed: .zero, shape: .arrow, videoCursor: true, at: 0)
        XCTAssertTrue(host.wantsCursorHidden(at: 0.1))
        host.noteFallback(at: 0.2)
        host.phoneHeartbeat(PointerSync(overlay: true), at: 0.3)
        XCTAssertFalse(host.wantsCursorHidden(at: 1.0))
        host.phoneHeartbeat(PointerSync(overlay: true), at: 2.1)
        XCTAssertFalse(host.wantsCursorHidden(at: 2.1))
        host.phoneHeartbeat(PointerSync(overlay: true), at: 2.3)
        XCTAssertTrue(host.wantsCursorHidden(at: 2.3))
    }

    func testPhoneAdvertisesOverlayOnlyWhileTelemetryIsFreshAndDrawsOnlyWhenVideoOmitsCursor() {
        var phone = PointerOverlayPolicy()
        XCTAssertNil(phone.advertisement(at: 0), "Legacy host: no envelope at all")
        phone.hostCapability(PointerSync(videoCursor: true), at: 0)
        XCTAssertEqual(phone.advertisement(at: 0), PointerSync(overlay: false))
        XCTAssertTrue(phone.telemetry(sample(1, videoCursor: true), at: 0.1))
        XCTAssertEqual(phone.advertisement(at: 0.2), PointerSync(overlay: true))
        XCTAssertFalse(phone.shouldDraw(at: 0.2, hasPosition: true), "Video still shows the Mac cursor: no duplicate")

        XCTAssertTrue(phone.telemetry(sample(2, videoCursor: false), at: 0.3))
        XCTAssertTrue(phone.shouldDraw(at: 0.3, hasPosition: true))
        XCTAssertFalse(phone.telemetry(sample(2, videoCursor: false), at: 0.31), "Replayed sample ignored")

        XCTAssertEqual(phone.advertisement(at: 1.2), PointerSync(overlay: false), "Stale telemetry asks for the captured cursor")
        XCTAssertTrue(phone.shouldDraw(at: 1.2, hasPosition: true), "Keep drawing until the host confirms the fallback")

        phone.hostCapability(PointerSync(videoCursor: true), at: 1.4)
        XCTAssertTrue(phone.shouldDraw(at: 1.5, hasPosition: true), "Grace covers frames still in flight")
        XCTAssertFalse(phone.shouldDraw(at: 1.8, hasPosition: true))

        XCTAssertTrue(phone.telemetry(sample(3, videoCursor: false, visible: false), at: 2))
        XCTAssertFalse(phone.shouldDraw(at: 2, hasPosition: true), "Pointer on another display is not drawn")
    }

    func testAShortTelemetryStallNeitherHidesThePointerNorWithdrawsTheOverlay() {
        var phone = PointerOverlayPolicy()
        phone.hostCapability(PointerSync(videoCursor: false), at: 0)
        XCTAssertTrue(phone.telemetry(sample(1, videoCursor: false), at: 0))
        // Wi-Fi/AWDL stalls seen on the phone: one ~100-150 ms gap every second; allow up to 500 ms.
        for gap in stride(from: 0.0, through: 0.5, by: 0.05) {
            XCTAssertTrue(phone.shouldDraw(at: gap, hasPosition: true), "Hidden after a \(gap) s gap")
            XCTAssertEqual(phone.advertisement(at: gap), PointerSync(overlay: true), "Withdrawn after a \(gap) s gap")
        }
        XCTAssertTrue(phone.telemetry(sample(3, videoCursor: false), at: 0.5))
        XCTAssertFalse(phone.telemetry(sample(2, videoCursor: false), at: 0.51), "A reordered older sample is dropped")
    }

    /// Runs both state machines against a delayed, ordered channel and checks that the
    /// pointer is never missing from what the phone shows and never hidden without telemetry.
    func testHandshakeNeverLeavesThePhoneWithoutAPointer() throws {
        var host = HostPointerTelemetryPolicy()
        var phone = PointerOverlayPolicy()
        var captureShows = true
        var toPhone: [(at: Double, action: RemoteAction)] = []
        var toHost: [(at: Double, action: RemoteAction)] = []
        let latency = 0.06
        // Frames already encoded keep their cursor setting for this long after a change.
        let pipeline = 0.12
        var videoShowsCursorAt: [(Double, Bool)] = [(0, true)]
        let telemetryOutage = 3.0...4.5

        func deliver(_ action: RemoteAction) throws -> RemoteAction {
            try action.validate()
            return try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action))
        }
        func videoHasCursor(at time: Double) -> Bool {
            videoShowsCursorAt.last(where: { $0.0 + pipeline <= time })?.1 ?? true
        }

        var hidAtLeastOnce = false
        var restoredAfterOutage = false
        for step in 0...(8 * 240) {
            let now = Double(step) / 240
            if step % 4 == 0 {
                let wanted = !host.wantsCursorHidden(at: now)
                if wanted != captureShows {
                    if wanted { host.noteFallback(at: now) }
                    captureShows = wanted
                    videoShowsCursorAt.append((now, wanted))
                    if !wanted { hidAtLeastOnce = true } else if now > telemetryOutage.lowerBound { restoredAfterOutage = true }
                }
                if !telemetryOutage.contains(now),
                   let sync = host.sample(observed: CGPoint(x: 100 + now * 10, y: 50), shape: .arrow,
                                          videoCursor: captureShows, at: now) {
                    toPhone.append((now + latency, try deliver(RemoteAction(action: "pointer", pointerSync: sync))))
                }
            }
            if step % 60 == 0 {
                toPhone.append((now + latency, try deliver(RemoteAction(action: "capture", x: 1,
                    pointerSync: PointerSync(videoCursor: captureShows)))))
                toHost.append((now + latency, try deliver(RemoteAction(action: "heartbeat",
                    pointerSync: phone.advertisement(at: now)))))
            }
            while let first = toPhone.first, first.at <= now {
                toPhone.removeFirst()
                if first.action.action == "capture" { phone.hostCapability(first.action.pointerSync, at: now) }
                else if let sync = first.action.pointerSync { _ = phone.telemetry(sync, at: now) }
            }
            while let first = toHost.first, first.at <= now {
                toHost.removeFirst()
                host.phoneHeartbeat(first.action.pointerSync, at: now)
            }
            let drawn = phone.shouldDraw(at: now, hasPosition: true)
            XCTAssertTrue(drawn || videoHasCursor(at: now), "Pointer missing at \(now)")
        }
        XCTAssertTrue(hidAtLeastOnce, "The negotiated overlay must actually take over")
        XCTAssertTrue(restoredAfterOutage, "A telemetry outage must restore the captured cursor")
        XCTAssertFalse(captureShows, "Telemetry recovered, so the overlay resumed after the cooldown")
    }

    @MainActor
    func testCaptureReportsHideIntentImmediatelyAndResetsToShownOnStop() {
        let capture = RemoteCapture()
        var reported: [Bool] = []
        capture.onCursorVisibility = { reported.append($0) }
        XCTAssertTrue(capture.cursorInVideo, "Every capture starts with the cursor in the video")
        capture.setShowsCursor(false)
        XCTAssertFalse(capture.cursorInVideo, "The phone must start drawing before frames lose the cursor")
        XCTAssertTrue(capture.appliedShowsCursor, "Nothing is applied before capture starts")
        capture.setShowsCursor(false)
        capture.setShowsCursor(true)
        XCTAssertTrue(capture.cursorInVideo)
        capture.setShowsCursor(false)
        _ = capture.stop()
        XCTAssertTrue(capture.cursorInVideo, "Stopping restores the default for the next session")
        XCTAssertEqual(reported, [false, true, false, true])
    }

    private func sample(_ number: UInt64, videoCursor: Bool, visible: Bool = true) -> PointerSync {
        PointerSync(videoCursor: videoCursor, x: 10, y: 10, visible: visible, shape: "arrow", sample: number)
    }
}

final class PointerSamplingTests: XCTestCase {
    func testSamplesDeduplicateKeepAliveAndCarryAcknowledgements() {
        var host = HostPointerTelemetryPolicy()
        host.phoneHeartbeat(PointerSync(overlay: true), at: 0)
        let first = host.sample(observed: CGPoint(x: 10.001, y: 20), shape: .arrow, videoCursor: true, at: 0)
        XCTAssertEqual(first?.x, 10)
        XCTAssertEqual(first?.sample, 1)
        XCTAssertNil(host.sample(observed: CGPoint(x: 10.002, y: 20), shape: .arrow, videoCursor: true, at: 0.016),
                     "Sub-1/64-point jitter is not resent")
        host.moveProcessed(ordinal: 5)
        host.moveProcessed(ordinal: 3)
        let acked = host.sample(observed: CGPoint(x: 10, y: 20), shape: .arrow, videoCursor: true, at: 0.033)
        XCTAssertEqual(acked?.applied, 5, "Acknowledgement advances even when the pointer is clamped still")
        XCTAssertNotNil(host.sample(observed: CGPoint(x: 10, y: 20), shape: .iBeam, videoCursor: true, at: 0.05))
        XCTAssertNil(host.sample(observed: CGPoint(x: 10, y: 20), shape: .iBeam, videoCursor: true, at: 0.1))
        let keepalive = host.sample(observed: CGPoint(x: 10, y: 20), shape: .iBeam, videoCursor: true, at: 0.31)
        XCTAssertEqual(keepalive?.sample, 4)
    }

    func testInjectedPointBridgesWindowServerLagAndOffDisplayIsInvisible() {
        var host = HostPointerTelemetryPolicy()
        host.phoneHeartbeat(PointerSync(overlay: true), at: 0)
        host.moveInjected(at: CGPoint(x: 50, y: 60), now: 1)
        host.phoneHeartbeat(PointerSync(overlay: true), at: 1)
        let bridged = host.sample(observed: CGPoint(x: 48, y: 60), shape: .arrow, videoCursor: false, at: 1.01)
        XCTAssertEqual(bridged?.x, 50)
        let settled = host.sample(observed: CGPoint(x: 48, y: 60), shape: .arrow, videoCursor: false, at: 1.6)
        XCTAssertEqual(settled?.x, 48, "After the settle window the observed position is authoritative")
        let away = host.sample(observed: nil, shape: .arrow, videoCursor: false, at: 1.65)
        XCTAssertEqual(away?.visible, false)
        XCTAssertEqual(away?.x, 48, "Last known position is kept for continuity")

        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(HostPointerTelemetryPolicy.displayPoint(CGPoint(x: -1, y: 899), in: frame), CGPoint(x: 1439, y: 899))
        XCTAssertNil(HostPointerTelemetryPolicy.displayPoint(CGPoint(x: 0, y: 10), in: frame))
        XCTAssertNil(HostPointerTelemetryPolicy.displayPoint(CGPoint(x: CGFloat.nan, y: 10), in: frame))
    }

    func testInjectedPointIsReportedUntilTheCursorCatchesUp() {
        var host = HostPointerTelemetryPolicy()
        host.phoneHeartbeat(PointerSync(overlay: true), at: 1)
        host.moveInjected(at: CGPoint(x: 200, y: 100), now: 1)
        // WindowServer is late on a loaded Mac: 80 ms after the post the cursor still reads the old spot.
        XCTAssertEqual(host.sample(observed: CGPoint(x: 150, y: 100), shape: .arrow, videoCursor: false, at: 1.08)?.x, 200,
                       "The acknowledged move is reported where it was placed, not where the cursor lags")
        XCTAssertNil(host.sample(observed: CGPoint(x: 200, y: 100), shape: .arrow, videoCursor: false, at: 1.1),
                     "Catching up reports nothing new")
        XCTAssertEqual(host.sample(observed: CGPoint(x: 205, y: 100), shape: .arrow, videoCursor: false, at: 1.12)?.x, 205,
                       "Once caught up, a physical mouse move is not masked for the rest of the window")

        host.phoneHeartbeat(PointerSync(overlay: true), at: 2)
        host.moveInjected(at: CGPoint(x: 300, y: 100), now: 2)
        XCTAssertEqual(host.sample(observed: CGPoint(x: 205, y: 100), shape: .arrow, videoCursor: false, at: 2.45)?.x, 300,
                       "A cursor still hundreds of milliseconds behind is bridged")
        host.phoneHeartbeat(PointerSync(overlay: true), at: 2.5)
        XCTAssertEqual(host.sample(observed: CGPoint(x: 205, y: 100), shape: .arrow, videoCursor: false, at: 2.55)?.x, 205,
                       "Bridging is bounded by the settle window")
    }
}

final class PointerPredictionTests: XCTestCase {
    func testLocalMovesMoveImmediatelyAndMatchingTelemetryCausesNoCorrection() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1440, height: 900))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        for index in 0..<5 {
            let ordinal = predictor.reserveOrdinal()
            predictor.applyLocalMove(ordinal: ordinal, delta: CGSize(width: 4, height: -2))
            XCTAssertEqual(predictor.displayed(at: 0.001 * Double(index)), CGPoint(x: 104 + 4 * CGFloat(index), y: 98 - 2 * CGFloat(index)))
        }
        // Delayed sample: host has applied three of the five moves.
        predictor.receive(point: CGPoint(x: 112, y: 94), applied: 3, at: 0.05)
        XCTAssertEqual(predictor.displayed(at: 0.05), CGPoint(x: 120, y: 90), "Unacknowledged moves are replayed, no snap back")
        XCTAssertFalse(predictor.correcting(at: 0.05))
        XCTAssertEqual(predictor.pendingCount, 2)
        predictor.receive(point: CGPoint(x: 120, y: 90), applied: 5, at: 0.1)
        XCTAssertEqual(predictor.pendingCount, 0)
        XCTAssertEqual(predictor.displayed(at: 0.1), CGPoint(x: 120, y: 90))
    }

    func testReplayClampsEachStepLikeTheHostDriver() {
        var cursor = CGPoint(x: 1430, y: 10)
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let sink = RemoteInputEventSink(
            pointerLocation: { cursor },
            mouseSequence: { events in cursor = events.last!.point; return true },
            scroll: { _, _, _ in true }, text: { _ in true }, key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.configure(bounds: bounds)
        driver.enabled = true

        var predictor = PointerPredictor(bounds: bounds.size)
        predictor.receive(point: cursor, applied: 0, at: 0)
        let deltas = [CGSize(width: 40, height: -30), CGSize(width: -25, height: 5), CGSize(width: -0.015625, height: 900),
                      CGSize(width: 12.5, height: -3)]
        for delta in deltas {
            predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: delta)
            XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: delta.width, y: delta.height)).accepted)
        }
        XCTAssertEqual(predictor.displayed(at: 0), cursor, "Per-step clamping must match the host exactly")
    }

    func testExternalMotionBlendsSmoothlyAndLargeJumpsSnap() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1000, height: 1000))
        predictor.receive(point: CGPoint(x: 500, y: 500), applied: nil, at: 0)
        predictor.receive(point: CGPoint(x: 520, y: 500), applied: nil, at: 1)
        XCTAssertEqual(predictor.displayed(at: 1), CGPoint(x: 500, y: 500), "No visible jump at the sample")
        XCTAssertTrue(predictor.correcting(at: 1))
        let midway = predictor.displayed(at: 1.045)!.x
        XCTAssertGreaterThan(midway, 510)
        XCTAssertLessThan(midway, 520)
        XCTAssertEqual(predictor.displayed(at: 1.5)!.x, 520, accuracy: 0.01)
        XCTAssertFalse(predictor.correcting(at: 1.5))

        predictor.receive(point: CGPoint(x: 900, y: 100), applied: nil, at: 2)
        XCTAssertEqual(predictor.displayed(at: 2), CGPoint(x: 900, y: 100), "A physical-mouse jump is shown immediately")
    }

    func testRejectedMovesConvergeWithoutPermanentOffset() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1000, height: 1000))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 10, height: 0))
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 10, height: 0))
        // The host processed both but, for example, control was withdrawn: nothing moved.
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 2, at: 0.1)
        XCTAssertEqual(predictor.pendingCount, 0)
        XCTAssertEqual(predictor.displayed(at: 0.1), CGPoint(x: 120, y: 100))
        XCTAssertEqual(predictor.displayed(at: 1)!.x, 100, accuracy: 0.01)
    }

    func testTrailingSamplesAreHeldWhileTheFingerMovesAndVanishWhenTheHostCatchesUp() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1000, height: 1000))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        var t = 0.0
        for _ in 1...10 {
            t += 1.0 / 120.0
            predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 5, height: 0), at: t)
        }
        XCTAssertEqual(predictor.displayed(at: t), CGPoint(x: 150, y: 100))
        // The host acknowledges all ten moves but its cursor still reads two moves behind.
        predictor.receive(point: CGPoint(x: 140, y: 100), applied: 10, at: t + 0.005)
        XCTAssertEqual(predictor.pendingCount, 0)
        XCTAssertEqual(predictor.displayed(at: t + 0.005), CGPoint(x: 150, y: 100), "No step backwards against the finger")
        XCTAssertTrue(predictor.holdingCorrection)
        XCTAssertEqual(predictor.displayed(at: t + 0.15)!.x, 150, accuracy: 0.001, "Held, not blended, while the finger is recent")
        t += 0.16
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 5, height: 0), at: t)
        XCTAssertEqual(predictor.displayed(at: t)!.x, 155, accuracy: 0.001, "The finger keeps the lead")
        predictor.receive(point: CGPoint(x: 155, y: 100), applied: 11, at: t + 0.01)
        XCTAssertEqual(predictor.displayed(at: t + 0.01)!.x, 155, accuracy: 0.001, "Catching up moves nothing")
        XCTAssertFalse(predictor.correcting(at: t + 0.01))
        XCTAssertFalse(predictor.holdingCorrection)
    }

    func testStallBurstOfTrailingSamplesKeepsTheDrawnPointerMonotonic() {
        var predictor = PointerPredictor(bounds: CGSize(width: 2000, height: 1000))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        var t = 0.0
        var queued: [(CGPoint, UInt64)] = []
        var xs: [CGFloat] = []
        for step in 1...48 {
            t += 1.0 / 120.0
            let ordinal = predictor.reserveOrdinal()
            predictor.applyLocalMove(ordinal: ordinal, delta: CGSize(width: 4, height: 0), at: t)
            if step % 2 == 0 {
                // Each host sample reports the cursor two moves behind its own acknowledgement.
                let hostPoint = CGPoint(x: 100 + CGFloat(max(0, Int(ordinal) - 2)) * 4, y: 100)
                if (12...30).contains(step) {
                    queued.append((hostPoint, ordinal))
                } else {
                    for (point, applied) in queued { predictor.receive(point: point, applied: applied, at: t) }
                    queued.removeAll()
                    predictor.receive(point: hostPoint, applied: ordinal, at: t)
                }
            }
            xs.append(predictor.displayed(at: t)!.x)
        }
        for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a, "Drawn x went backwards: \(xs)") }
        XCTAssertEqual(xs.last!, 100 + 48 * 4, accuracy: 0.001, "The finger's own motion is authoritative throughout")
    }

    func testAHeldCorrectionBlendsOutOnceTheFingerRests() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1000, height: 1000))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 20, height: 0), at: 1)
        // Rejected by the host (control withdrawn): acknowledged, nothing moved.
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 1, at: 1.02)
        XCTAssertEqual(predictor.displayed(at: 1.02)!.x, 120, accuracy: 0.001)
        XCTAssertEqual(predictor.displayed(at: 1.19)!.x, 120, accuracy: 0.001, "Nothing moves back while the finger may still be moving")
        XCTAssertTrue(predictor.correcting(at: 1.19), "Still pending, so the render loop stays alive")
        XCTAssertLessThan(predictor.displayed(at: 1.25)!.x, 120)
        XCTAssertEqual(predictor.displayed(at: 1.6)!.x, 100, accuracy: 0.01, "Then it blends to the host's truth")
    }

    func testReversingTheFingerReleasesAHeldCorrection() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1000, height: 1000))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 20, height: 0), at: 1)
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 1, at: 1.02)
        XCTAssertTrue(predictor.holdingCorrection)
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: -5, height: 0), at: 1.03)
        XCTAssertFalse(predictor.holdingCorrection, "Moving back towards the host's position lets the residual blend")
        XCTAssertEqual(predictor.displayed(at: 1.03)!.x, 115, accuracy: 0.001)
        XCTAssertEqual(predictor.displayed(at: 1.5)!.x, 95, accuracy: 0.01)
    }

    func testMovesBeforeTheFirstSampleAreReplayedAndOrdinalsRestartPerEpoch() {
        var predictor = PointerPredictor(bounds: CGSize(width: 100, height: 100))
        XCTAssertNil(predictor.displayed(at: 0))
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 5, height: 5))
        XCTAssertNil(predictor.displayed(at: 0), "Nothing is drawn without an authoritative anchor")
        predictor.receive(point: CGPoint(x: 10, y: 10), applied: 0, at: 0)
        XCTAssertEqual(predictor.displayed(at: 0), CGPoint(x: 15, y: 15))
        predictor.reset(bounds: CGSize(width: 50, height: 50))
        XCTAssertEqual(predictor.reserveOrdinal(), 1)
        XCTAssertNil(predictor.displayed(at: 0))
    }
}

final class CursorShapeClassifierTests: XCTestCase {
    @MainActor
    func testStandardCursorsClassifyAndForeignArtworkIsUnknown() throws {
        _ = NSApplication.shared
        let references = CursorShapeClassifier.standardReferences()
        XCTAssertGreaterThan(references.count, 20)
        let expectations: [(NSCursor, PointerShape)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand), (.openHand, .openHand),
            (.closedHand, .closedHand), (.crosshair, .crosshair), (.operationNotAllowed, .notAllowed),
            (.dragCopy, .dragCopy), (.columnResize, .resizeLeftRight), (.rowResize, .resizeUpDown),
            (.frameResize(position: .topLeft, directions: .all), .resizeNorthWestSouthEast),
            (.frameResize(position: .bottomLeft, directions: .all), .resizeNorthEastSouthWest)
        ]
        for (cursor, shape) in expectations {
            let print = try XCTUnwrap(CursorFingerprint(image: cursor.image, hotSpot: cursor.hotSpot))
            XCTAssertEqual(CursorShapeClassifier.classify(print, references: references), shape)
        }

        // An enlarged accessibility pointer keeps its proportions and hot spot.
        let arrow = NSCursor.arrow
        let large = NSImage(size: NSSize(width: arrow.image.size.width * 3, height: arrow.image.size.height * 3),
                            flipped: false) { rect in arrow.image.draw(in: rect); return true }
        let enlarged = try XCTUnwrap(CursorFingerprint(image: large, hotSpot: NSPoint(x: arrow.hotSpot.x * 3, y: arrow.hotSpot.y * 3)))
        XCTAssertEqual(CursorShapeClassifier.classify(enlarged, references: references), .arrow)

        for reference in references {
            XCTAssertEqual(CursorShapeClassifier.classify(reference.fingerprint, references: references), reference.shape)
        }

        // Custom pointer colours (Accessibility > Display > Pointer) change tone, not silhouette.
        let recoloured = NSImage(size: arrow.image.size, flipped: false) { rect in
            arrow.image.draw(in: rect)
            NSColor.systemPink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let tinted = try XCTUnwrap(CursorFingerprint(image: recoloured, hotSpot: arrow.hotSpot))
        XCTAssertEqual(CursorShapeClassifier.classify(tinted, references: references), .arrow)

        let square = NSImage(size: NSSize(width: 28, height: 40), flipped: false) { rect in
            NSColor.black.setFill(); rect.fill(); return true
        }
        let foreign = try XCTUnwrap(CursorFingerprint(image: square, hotSpot: NSPoint(x: 5, y: 5)))
        XCTAssertEqual(CursorShapeClassifier.classify(foreign, references: references), .unknown)
    }

    func testAccessibilityFallbackMapsOnlyEditableTextAndLinks() {
        XCTAssertEqual(CursorShapeClassifier.shape(role: "AXTextField", subrole: nil), .iBeam)
        XCTAssertEqual(CursorShapeClassifier.shape(role: "AXTextArea", subrole: nil), .iBeam)
        XCTAssertEqual(CursorShapeClassifier.shape(role: "AXLink", subrole: nil), .pointingHand)
        XCTAssertEqual(CursorShapeClassifier.shape(role: "AXStaticText", subrole: nil), .arrow)
        XCTAssertEqual(CursorShapeClassifier.shape(role: "AXGroup", subrole: "AXSearchField"), .iBeam)
        XCTAssertEqual(CursorShapeClassifier.shape(role: nil, subrole: nil), .arrow)
    }
}

final class PointerGlyphTests: XCTestCase {
    func testEveryShapeHasDrawableArtworkAroundItsHotSpot() {
        XCTAssertGreaterThan(PointerGlyph.nominalHeight, 15)
        for shape in PointerShape.allCases {
            let glyph = PointerGlyph.glyph(for: shape)
            let bounds = glyph.bounds
            XCTAssertFalse(glyph.layers.isEmpty, "\(shape)")
            XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint.zero), "\(shape) hot spot outside artwork")
            XCTAssertLessThan(max(bounds.width, bounds.height), 30, "\(shape) is disproportionate")
        }
        let arrow = PointerGlyph.glyph(for: .arrow).bounds
        XCTAssertEqual(arrow.minX, -1.25, accuracy: 0.01, "Arrow hot spot is its tip")
        XCTAssertEqual(arrow.minY, -1.25, accuracy: 0.01)
    }

    func testRendererDrawsOpaquePixelsAtTheHotSpot() throws {
        let size = 64
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 32, y: 32)
        context.scaleBy(x: 2, y: -2)
        PointerGlyphRenderer.draw(PointerGlyph.glyph(for: .crosshair), in: context)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(data[(32 * size + 32) * 4 + 3], 255, "Crosshair centre is drawn at the hot spot")
        XCTAssertEqual(data[(2 * size + 2) * 4 + 3], 0, "Corners stay transparent")
    }
}
