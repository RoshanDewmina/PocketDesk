import XCTest
import CoreGraphics

final class TabletInputTests: XCTestCase {
    private let stream = String(repeating: "a", count: 32)
    private func pen(_ phase: PencilFrame.Phase, pressure: Double = 0.6) -> PencilFrame {
        PencilFrame(stream: stream, phase: phase, pressure: pressure, tiltX: 0.3, tiltY: -0.4)
    }
    private func action(_ name: String, _ frame: PencilFrame) -> RemoteAction {
        RemoteAction(action: name, x: name == "moveTo" ? 120 : 0, y: name == "moveTo" ? 130 : 0, epoch: 7,
                     interaction: NativeInteraction(hold: stream, clickCount: 1), pencil: frame)
    }
    func testMetadataCannotRideOtherActionsOrMalformedContactAndOldPacketStillDecodes() throws {
        XCTAssertNoThrow(try action("dragDown", pen(.began)).validate())
        XCTAssertNoThrow(try action("moveTo", pen(.moved)).validate())
        XCTAssertThrowsError(try action("key", pen(.moved)).validate())
        XCTAssertThrowsError(try action("moveTo", pen(.hover)).validate())
        XCTAssertThrowsError(try action("dragUp", pen(.ended)).validate())
        var invalid = pen(.began); invalid.pressure = .nan
        XCTAssertThrowsError(try action("dragDown", invalid).validate())
        invalid.pressure = 2; XCTAssertThrowsError(try action("dragDown", invalid).validate())
        var mixed = action("dragDown", pen(.began)); mixed.interaction?.hold = "other"
        XCTAssertThrowsError(try mixed.validate())
        let ordinary = RemoteAction(action: "moveTo", x: 5, y: 6)
        XCTAssertNil(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(ordinary)).pencil)
    }
    func testActualPublicEventConstructorPopulatesPressureTiltSubtypeAndZeroCleanup() throws {
        let frame = pen(.moved)
        let event = try XCTUnwrap(RemoteInputEventSink.makeMouseEvent(.init(type: .leftMouseDragged, point: CGPoint(x: 20, y: 30), button: .left, count: 1, pencil: frame)))
        XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype), Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(event.getDoubleValueField(.mouseEventPressure), 0.6, accuracy: 0.0001)
        XCTAssertEqual(event.getDoubleValueField(.tabletEventPointPressure), 0.6, accuracy: 0.0001)
        XCTAssertEqual(event.getDoubleValueField(.tabletEventTiltX), 0.3, accuracy: 0.0001)
        XCTAssertEqual(event.getDoubleValueField(.tabletEventTiltY), -0.4, accuracy: 0.0001)
        XCTAssertEqual(event.getIntegerValueField(.tabletEventPointButtons), 1)
        let up = try XCTUnwrap(RemoteInputEventSink.makeMouseEvent(.init(type: .leftMouseUp, point: .zero, button: .left, count: 1, pencil: frame.zeroed())))
        XCTAssertEqual(up.getDoubleValueField(.mouseEventPressure), 0)
        XCTAssertEqual(up.getDoubleValueField(.tabletEventPointPressure), 0)
        XCTAssertEqual(up.getIntegerValueField(.tabletEventPointButtons), 0)
    }
    func testRealDriverPreservesContactIdentityAndRevokeProducesPressureZeroMouseUp() {
        var events: [RemoteInputEventSink.MouseEvent] = []
        let sink = RemoteInputEventSink(pointerLocation: { CGPoint(x: 100, y: 100) }, mouseSequence: { events += $0; return true }, scroll: { _, _, _ in true }, text: { _ in true }, key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)); driver.enabled = true
        XCTAssertTrue(driver.handle(action("dragDown", pen(.began)), upgraded: true, now: 10).accepted)
        XCTAssertTrue(driver.handle(action("moveTo", pen(.moved, pressure: 0.9)), upgraded: true, now: 10.01).accepted)
        var foreign = action("moveTo", pen(.moved)); foreign.pencil = PencilFrame(stream: String(repeating: "b", count: 32), phase: .moved, pressure: 0.7, tiltX: 0, tiltY: 0); foreign.interaction?.hold = foreign.pencil?.stream
        XCTAssertFalse(driver.handle(foreign, upgraded: true, now: 10.02).accepted)
        XCTAssertFalse(driver.handle(RemoteAction(action: "move", x: 2, interaction: NativeInteraction(hold: stream, clickCount: 1)), upgraded: true, now: 10.02).accepted)
        XCTAssertTrue(driver.release()); XCTAssertFalse(driver.held)
        XCTAssertEqual(events.map { $0.type }, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(events.map { $0.pencil?.pressure }, [0.6, 0.9, 0])
        XCTAssertFalse(driver.handle(action("dragDown", pen(.began)), upgraded: true, now: 10.03).accepted, "retired contact cannot restart")
    }
    func testPencilLifecycleCannotMixContactsAndGeometryCancelsExactlyOnce() {
        let router = PencilContactRouter(); var phases: [PencilFrame.Phase] = []
        router.send = { _, frame in phases.append(frame.phase); return true }
        router.configure(enabled: true, revision: 7)
        XCTAssertTrue(router.begin(at: .zero, pressure: 0.5, tiltX: 0, tiltY: 0))
        XCTAssertFalse(router.begin(at: .zero, pressure: 0.9, tiltX: 0, tiltY: 0))
        router.hover(at: .zero, tiltX: 0, tiltY: 0)
        XCTAssertTrue(router.move(to: CGPoint(x: 1, y: 2), pressure: 0.7, tiltX: 0.2, tiltY: 0))
        router.updatePressure(pressure: 0.9, tiltX: 0.1, tiltY: 0)
        router.configure(enabled: true, revision: 8); router.cancel()
        XCTAssertEqual(phases, [.began, .moved, .moved, .cancelled]); XCTAssertNil(router.active)
        router.configure(enabled: false, revision: 8)
        XCTAssertFalse(router.begin(at: .zero, pressure: 1, tiltX: 0, tiltY: 0))
    }
    func testLiftOutsideMappedCanvasFallsBackToCancelledContactAtLastAcceptedPoint() {
        let router = PencilContactRouter(); var deliveries: [(CGPoint, PencilFrame.Phase)] = []
        router.send = { point, frame in deliveries.append((point, frame.phase)); return point.x < 200 }
        router.configure(enabled: true, revision: 1)
        XCTAssertTrue(router.begin(at: CGPoint(x: 50, y: 60), pressure: 0.5, tiltX: 0, tiltY: 0))
        router.end(at: CGPoint(x: 300, y: 60))
        XCTAssertEqual(deliveries.map { $0.1 }, [.began, .ended, .cancelled])
        XCTAssertEqual(deliveries.last?.0, CGPoint(x: 50, y: 60)); XCTAssertNil(router.active)
    }
    func testWorstCasePressurePrefixAndReliableTextRemainInsideControlPacketBound() throws {
        let token = String(repeating: "t", count: 64)
        let frames = (1...24).map { ordinal in
            RemoteAction(action: "moveTo", x: 19999.9999999999, y: 19999.9999999999, modifiers: ["command", "shift", "option", "control"], epoch: UInt64.max,
                interaction: NativeInteraction(token: token, hold: stream, clickCount: 1),
                pencil: PencilFrame(stream: stream, phase: .moved, pressure: 0.99999999999999, tiltX: -0.99999999999999, tiltY: -0.99999999999999),
                pointerSync: PointerSync(move: UInt64(ordinal)))
        }
        var prefix = InputMotionPrefix()
        for frame in frames { if prefix.canAppend(frame) { try prefix.append(frame) } else { break } }
        XCTAssertLessThan(prefix.segments.count, 24, "Byte budget must checkpoint heavy pressure state before the count cap")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(prefix.segments).count, InputMotionPrefix.maximumEncodedSegmentsBytes)
        let context = InputCausalEnvelope(kind: "barrier", nonce: stream, anchor: stream, epoch: UInt64.max, applied: prefix.next, segments: prefix.segments)
        let packet = ControlPacket(session: String(repeating: "s", count: 64), sequence: UInt64.max,
            action: RemoteAction(action: "text", text: String(repeating: "\u{0000}", count: 1024), key: String(repeating: "k", count: 32), epoch: UInt64.max, interaction: NativeInteraction(token: token)), input: context)
        try context.validate(); try packet.action.validate()
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(packet).count, 16384)
    }
    @MainActor
    func testPressureByteOverflowCheckpointsBeforeAcceptedTextAndRetainsEveryOrdinal() throws {
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), signaling: ScriptedSignaling())
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), signaling: ScriptedSignaling())
        host.startInputFixtureForTesting(session: "pressure"); phone.startInputFixtureForTesting(session: "pressure")
        defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        host.setHostInputEpoch(7); phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst()); try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        let moves = (1...24).map { index in
            RemoteAction(action: "moveTo", x: Double(index), y: 19999.9999999999, modifiers: ["command", "shift", "option", "control"], epoch: 7,
                interaction: NativeInteraction(token: String(repeating: "t", count: 64), hold: stream, clickCount: 1),
                pencil: PencilFrame(stream: stream, phase: .moved, pressure: 0.99999999999999, tiltX: -0.99999999999999, tiltY: -0.99999999999999))
        }
        XCTAssertTrue(phone.sendInputMoves(moves)); XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "after pressure", key: "request", epoch: 7)))
        XCTAssertFalse(upstream.contains { $0.action.action == "text" })
        let first = upstream.removeFirst(); let prefix = try XCTUnwrap(first.input)
        XCTAssertLessThan(prefix.applied, 24)
        try host.receiveInputFixtureForTesting(first)
        host.acknowledgeCausalInput(prefix, applied: prefix.applied)
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        let text = try XCTUnwrap(upstream.last { $0.action.action == "text" })
        XCTAssertEqual(text.input?.applied, 24)
        XCTAssertEqual(prefix.segments.map(\.ordinal) + (text.input?.segments.map(\.ordinal) ?? []), Array(1...24).map(UInt64.init))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(text).count, 16384)
    }
    func testRelativeDeltaGateClampsNeitherPathNorAuthorityAndLossReleasesHold() {
        let router = LockedRelativeMouseRouter(); var moves: [CGSize] = [], downs = 0, ups = 0
        router.send = { command in
            switch command { case .move(let delta): moves.append(delta); case .dragBegan: downs += 1; case .dragEnded: ups += 1; default: break }
            return true
        }
        router.move(x: 3, y: 4, gain: 2); XCTAssertTrue(moves.isEmpty)
        router.setEnabled(true); router.primary(true); router.primary(true)
        router.move(x: 3, y: 4, gain: 2); router.move(x: .infinity, y: 0, gain: 1)
        router.setEnabled(false); router.primary(false); router.move(x: 10, y: 10, gain: 1)
        XCTAssertEqual(moves, [CGSize(width: 6, height: -8)]); XCTAssertEqual(downs, 1); XCTAssertEqual(ups, 1)
    }
    func testQueuedContactIsCancelledByEpochAndPressureMotionPrecedesReliableLift() {
        let queue = DispatchQueue(label: "pencil.queue"); var events: [RemoteInputEventSink.MouseEvent] = []
        var pointer = CGPoint(x: 100, y: 100)
        let sink = RemoteInputEventSink(pointerLocation: { pointer }, mouseSequence: { events += $0; pointer = $0.last?.point ?? pointer; return true }, scroll: { _, _, _ in true }, text: { _ in true }, key: { _, _ in true })
        let executor = HostInputExecutor(driver: RemoteInputDriver(eventSink: sink, isTrusted: { true }), queue: queue, clock: { 10 })
        executor.configure(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)); executor.enabled = true
        let context = InputCausalEnvelope(kind: "barrier", nonce: stream, anchor: String(repeating: "b", count: 32), epoch: 7)
        executor.beginCausalContext(context); executor.drain(); queue.suspend()
        let done = expectation(description: "retired pen")
        executor.submitCausal(context, steps: [], semantic: .init(action: action("dragDown", pen(.began)), upgraded: true, expires: 11), routeAuthority: { $0() }) { result in
            XCTAssertTrue(result.failed); done.fulfill()
        }
        var next = context; next.epoch = 8
        executor.release(); executor.beginCausalContext(next)
        queue.resume(); wait(for: [done], timeout: 2); executor.drain()
        XCTAssertTrue(events.isEmpty); XCTAssertFalse(executor.held)
        // New current scope uses existing ledger and reliable lift, not a new unchecked path.
        let down = expectation(description: "current pen")
        var currentDown = action("dragDown", pen(.began)); currentDown.epoch = 8
        executor.submitCausal(next, steps: [], semantic: .init(action: currentDown, upgraded: true, expires: 11), routeAuthority: { $0() }) { _ in down.fulfill() }
        wait(for: [down], timeout: 2)
        var move = action("moveTo", pen(.moved, pressure: 0.8)); move.epoch = 8
        var lifted = next; lifted.applied = 1; lifted.segments = [.init(ordinal: 1, action: move)]
        var up = action("dragUp", pen(.ended, pressure: 0)); up.epoch = 8
        let lift = expectation(description: "pressure before up")
        executor.submitCausal(lifted, steps: [.init(action: move, upgraded: true, expires: 11)], semantic: .init(action: up, upgraded: true, expires: 11), routeAuthority: { $0() }) { result in
            XCTAssertFalse(result.failed); XCTAssertEqual(result.applied, 1); lift.fulfill()
        }
        wait(for: [lift], timeout: 2)
        XCTAssertEqual(events.map { $0.type }, [.leftMouseDown, .leftMouseDragged, .leftMouseUp]); XCTAssertEqual(events.map { $0.pencil?.pressure }, [0.6, 0.8, 0])
    }
}
