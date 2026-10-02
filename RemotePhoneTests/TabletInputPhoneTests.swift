import XCTest
@testable import PocketDeskRemote

@MainActor
final class TabletInputPhoneTests: XCTestCase {
    func testActualPublicControllerRequestsButDoesNotAssumeSceneLockAndEndsOnce() {
        var actions = 0, ends = 0
        let controller = LockedMouseController(revision: 7, gain: 1, send: { _ in actions += 1; return true }, key: { _, _ in true }, modifiers: { _ in })
        controller.onEnded = { _ in ends += 1 }
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.prefersPointerLocked)
        controller.viewDidAppear(false)
        XCTAssertFalse(HardwarePeripherals.shared.pointerIsLocked, "No scene can provide a genuine lock in this fixture")
        controller.finish("fixture end"); controller.finish("duplicate")
        XCTAssertFalse(controller.prefersPointerLocked); XCTAssertEqual(actions, 0); XCTAssertEqual(ends, 1)
    }
    func testNativeMouseOwnerGenerationRefusesOldHandlerAndNoLockRawDelta() {
        let hardware = HardwarePeripherals.shared
        let first = NSObject(), second = NSObject()
        var actual = false, firstMoves = 0, secondMoves = 0, lost = 0
        let a = hardware.claimLockedMouse(owner: first, gate: { actual }, move: { _, _ in firstMoves += 1 }, button: { _, _ in }, lost: { lost += 1 })
        hardware.deliverLockedMove(x: 1, y: 2, generation: a)
        XCTAssertEqual(firstMoves, 0, "Preference without actual gate proof refuses raw movement")
        actual = true
        hardware.deliverLockedMove(x: 1, y: 2, generation: a); XCTAssertEqual(firstMoves, 1)
        let b = hardware.claimLockedMouse(owner: second, gate: { actual }, move: { _, _ in secondMoves += 1 }, button: { _, _ in }, lost: {})
        XCTAssertEqual(lost, 1)
        hardware.releaseLockedMouse(owner: first, generation: a)
        hardware.deliverLockedMove(x: 1, y: 2, generation: a); XCTAssertEqual(firstMoves, 1)
        hardware.deliverLockedMove(x: 1, y: 2, generation: b); XCTAssertEqual(secondMoves, 1)
        hardware.releaseLockedMouse(owner: second, generation: b)
        hardware.deliverLockedMove(x: 1, y: 2, generation: b); XCTAssertEqual(secondMoves, 1)
    }
    func testActualPhonePencilContactUsesCausalStateBeforeDownAndLiftAndGeometryRetiresHold() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture)
        model.connection.startInputFixtureForTesting(session: "pencil")
        defer { model.connection.stop() }
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 7))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 7, interaction: NativeInteraction(token: "t", doubleClickInterval: 0.5), features: SessionFeature.host, mode: "picture"))
        model.frameReceived(); model.pencilEnabled = true
        XCTAssertFalse(model.pencilSupported, "Advertised pen alone cannot bypass the causal handshake")
        var context = try XCTUnwrap(packets.first { $0.input?.kind == "offer" }?.input)
        context.kind = "accept"; context.anchor = String(repeating: "b", count: 32)
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "pencil", sequence: 1, action: RemoteAction(action: "heartbeat", epoch: 7), input: context))
        XCTAssertTrue(model.pencilSupported)
        let stream = String(repeating: "a", count: 32)
        let began = PencilFrame(stream: stream, phase: .began, pressure: 0.4, tiltX: 0.2, tiltY: -0.1)
        XCTAssertTrue(model.pencil(at: CGPoint(x: 30, y: 40), frame: began))
        let down = try XCTUnwrap(packets.last { $0.action.action == "dragDown" })
        XCTAssertEqual(down.input?.kind, "barrier"); XCTAssertEqual(down.input?.segments.last?.action.action, "moveTo")
        XCTAssertEqual(down.input?.segments.last?.action.pencil?.pressure, 0)
        var moved = began; moved.phase = .moved; moved.pressure = 0.8
        XCTAssertTrue(model.pencil(at: CGPoint(x: 35, y: 45), frame: moved))
        XCTAssertTrue(model.pencil(at: CGPoint(x: 36, y: 46), frame: moved.zeroed(.ended)))
        let up = try XCTUnwrap(packets.last { $0.action.action == "dragUp" })
        XCTAssertEqual(up.input?.kind, "barrier"); XCTAssertEqual(up.input?.segments.last?.action.x, 36)
        XCTAssertEqual(up.action.pencil?.pressure, 0); XCTAssertFalse(model.dragging)
        XCTAssertTrue(model.pencil(at: CGPoint(x: 50, y: 60), frame: PencilFrame(stream: String(repeating: "c", count: 32), phase: .began, pressure: 0.5, tiltX: 0, tiltY: 0)))
        context.kind = "anchor"; context.epoch = 8; context.anchor = String(repeating: "d", count: 32)
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "pencil", sequence: 2, action: RemoteAction(action: "heartbeat", epoch: 8), input: context))
        XCTAssertFalse(model.dragging); XCTAssertFalse(model.canControl); XCTAssertTrue(model.connection.connected)
    }
    func testActualPhoneScrollModifiersReachValidatedWireWithoutAbsolutePointerCapability() throws {
        for enabled in [true, false] {
            for native in [true, false] {
                let model = PhoneRemoteModel(background: FakeBackgroundExecution())
                model.scrollModifiers = enabled
                model.prepareConnection(mode: .picture)
                model.connection.startInputFixtureForTesting(session: "scroll")
                defer { model.connection.stop() }
                var packets: [ControlPacket] = []
                model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
                func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
                try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
                try deliver(RemoteAction(action: "viewing", x: 1, epoch: 7))
                try deliver(RemoteAction(action: "capture", x: 1, epoch: 7,
                    interaction: native ? NativeInteraction(token: "t", doubleClickInterval: 0.5) : nil,
                    features: SessionFeature.host.filter { $0 != SessionFeature.absolutePointer }, mode: "picture"))
                model.frameReceived()
                XCTAssertFalse(model.connection.causalInputNegotiated, "Advertised features alone do not establish causal authority")
                var context = try XCTUnwrap(packets.first { $0.input?.kind == "offer" }?.input)
                context.kind = "accept"; context.anchor = String(repeating: "b", count: 32)
                try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "scroll", sequence: 1,
                    action: RemoteAction(action: "heartbeat", epoch: 7), input: context))
                XCTAssertTrue(model.canControl)
                XCTAssertTrue(model.connection.causalInputNegotiated)
                XCTAssertFalse(model.absolutePointerSupported)
                for modifier in ["control", "shift", "option"] {
                    model.hardwareModifiers = [modifier]
                    let stream = UUID().uuidString
                    XCTAssertTrue(model.gesture(.scroll(delta: CGSize(width: 0.25, height: -0.125), phase: "began", stream: stream)))
                    XCTAssertTrue(model.gesture(.scroll(delta: .zero, phase: "ended", stream: stream)))
                    for packet in packets.suffix(2) {
                        let wire = try JSONDecoder().decode(ControlPacket.self, from: JSONEncoder().encode(packet))
                        try wire.action.validate()
                        XCTAssertEqual(wire.action.action, "scroll")
                        XCTAssertEqual(wire.action.modifiers, enabled ? [modifier] : [])
                        XCTAssertEqual(wire.action.interaction?.stream, native ? stream : nil)
                    }
                }
                model.cancelInput(); model.hardwareModifiers = []
                XCTAssertTrue(model.gesture(.scroll(delta: CGSize(width: 1, height: 1), phase: "began", stream: UUID().uuidString)))
                XCTAssertEqual(packets.last?.action.modifiers, [], "Released hardware flags do not remain on later scrolls")
            }
        }
    }

    /// 20260930.8 hang reports: resigning synchronously inside SwiftUI's updateUIView asked the
    /// hosting view whether it could become first responder, re-entering the update graph.
    @MainActor
    func testKeyboardFocusReleaseWaitsForTheUpdateToFinish() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let view = NativeTrackpadInputView(frame: window.bounds)
        window.addSubview(view); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.setKeyboardFocus(true)
        await Task.yield(); try? await Task.sleep(for: .milliseconds(50))
        try XCTSkipUnless(view.isFirstResponder, "this test host cannot hand out first responder")
        view.setKeyboardFocus(false)
        XCTAssertTrue(view.isFirstResponder, "no responder-chain walk inside the caller's update")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(view.isFirstResponder)

        view.setKeyboardFocus(true); try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(view.isFirstResponder)
        view.setKeyboardFocus(false); view.setKeyboardFocus(true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(view.isFirstResponder, "a release overtaken by a new claim keeps focus")
    }
    func testUnderlyingCanvasUpdateCannotStealLockedKeyboardDisconnectOrFocus() async {
        let hardware = HardwarePeripherals.shared
        let locked = NativeTrackpadInputView(), underlying = NativeTrackpadInputView(), owner = NSObject()
        var keys = 0, cleared = 0
        locked.keyboard.send = { _, _ in keys += 1; return true }
        locked.keyboard.modifiersChanged = { modifiers in if modifiers.isEmpty { cleared += 1 } }
        let generation = hardware.claimLockedMouse(owner: owner, gate: { true }, move: { _, _ in }, button: { _, _ in }, lost: {},
            keyboardOwner: locked, keyboardDisconnect: { locked.keyboard.releaseAll() })
        defer { hardware.releaseLockedMouse(owner: owner, generation: generation) }
        XCTAssertTrue(locked.canBecomeFirstResponder); XCTAssertFalse(underlying.canBecomeFirstResponder)
        XCTAssertTrue(locked.keyboard.pressBegan(usage: 4, flags: [.shift], at: ProcessInfo.processInfo.systemUptime))
        underlying.bindPeripheralHandlers(); underlying.setKeyboardFocus(true)
        hardware.deliverKeyboardDisconnect()
        XCTAssertTrue(locked.keyboard.heldModifiers.isEmpty); XCTAssertEqual(cleared, 1)
        let sent = keys
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(keys, sent, "Disconnect cancels the actual locked router's repeat timer")
        hardware.releaseLockedMouse(owner: owner, generation: generation)
        XCTAssertTrue(underlying.canBecomeFirstResponder)
    }

}
