import XCTest
import AppKit
import CoreGraphics
import Network
import ScreenCaptureKit
import WebRTC

// MARK: - Momentum scrolling (O7)

final class ScrollMomentumPhaseTests: XCTestCase {
    func testGesturePhasesAndMomentumPhasesMapToTheMacsFields() {
        XCTAssertEqual(ScrollEventPhases.values(for: "began").scroll, 1)
        XCTAssertEqual(ScrollEventPhases.values(for: "changed").scroll, 2)
        XCTAssertEqual(ScrollEventPhases.values(for: "ended").scroll, 4)
        XCTAssertEqual(ScrollEventPhases.values(for: "cancelled").scroll, 8)
        for phase in ["began", "changed", "ended", "cancelled"] {
            XCTAssertEqual(ScrollEventPhases.values(for: phase).momentum, 0, "\(phase) is a finger phase only")
        }
        XCTAssertEqual(ScrollEventPhases.values(for: "momentumBegan").momentum, Int64(CGMomentumScrollPhase.begin.rawValue))
        XCTAssertEqual(ScrollEventPhases.values(for: "momentumChanged").momentum, Int64(CGMomentumScrollPhase.continuous.rawValue))
        XCTAssertEqual(ScrollEventPhases.values(for: "momentumEnded").momentum, Int64(CGMomentumScrollPhase.end.rawValue))
        for phase in ScrollMomentumPhase.allCases {
            XCTAssertEqual(ScrollEventPhases.values(for: phase.rawValue).scroll, 0, "Momentum carries no finger phase")
        }
        XCTAssertTrue(ScrollEventPhases.values(for: "momentum") == (0, 0), "The old placeholder posts no phase")
    }

    func testMomentumPhasesValidateOnTheWire() {
        for phase in ScrollMomentumPhase.allCases {
            XCTAssertNoThrow(try RemoteAction(action: "scroll", x: 0, y: 4,
                interaction: NativeInteraction(token: "t", phase: phase.rawValue, stream: "s")).validate())
        }
        XCTAssertThrowsError(try RemoteAction(action: "scroll",
            interaction: NativeInteraction(token: "t", phase: "momentumSideways", stream: "s")).validate())
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.momentumScroll))
    }

    func testGateAdmitsOneMomentumOnlyForTheStreamThatJustEnded() {
        var gate = ScrollMomentumGate()
        XCTAssertEqual(gate.admit(.began, stream: "a", at: 1), .reject, "No gesture ended yet")
        gate.gestureEnded(stream: "a", at: 1)
        XCTAssertEqual(gate.admit(.began, stream: "b", at: 1.01), .reject, "Another stream")
        XCTAssertEqual(gate.admit(.changed, stream: "a", at: 1.01), .reject, "Must begin first")
        XCTAssertEqual(gate.admit(.began, stream: "a", at: 1.02), .post)
        XCTAssertEqual(gate.admit(.began, stream: "a", at: 1.03), .reject, "Only once")
        XCTAssertEqual(gate.admit(.changed, stream: "a", at: 1.04), .post)
        XCTAssertEqual(gate.admit(.ended, stream: "a", at: 1.05), .post)
        XCTAssertEqual(gate.admit(.changed, stream: "a", at: 1.06), .reject, "Ended")
    }

    func testGateRefusesLateStartsAndExpiresQuietMomentum() {
        var late = ScrollMomentumGate()
        late.gestureEnded(stream: "a", at: 1)
        XCTAssertEqual(late.admit(.began, stream: "a", at: 1 + ScrollMomentumGate.startWindow), .reject)

        var quiet = ScrollMomentumGate()
        quiet.gestureEnded(stream: "a", at: 1)
        XCTAssertEqual(quiet.admit(.began, stream: "a", at: 1.1), .post)
        XCTAssertFalse(quiet.expire(at: 1.3))
        XCTAssertTrue(quiet.expire(at: 1.1 + ScrollMomentumGate.idleLimit), "Silence ends it")
        XCTAssertNil(quiet.active)
        XCTAssertFalse(quiet.expire(at: 5), "Only once")

        var interrupted = ScrollMomentumGate()
        XCTAssertFalse(interrupted.interrupt(), "Nothing running")
        interrupted.gestureEnded(stream: "a", at: 1)
        XCTAssertEqual(interrupted.admit(.began, stream: "a", at: 1.1), .post)
        XCTAssertTrue(interrupted.interrupt())
        XCTAssertEqual(interrupted.admit(.changed, stream: "a", at: 1.2), .reject)
    }
}

final class MomentumDriverTests: XCTestCase {
    private var posted: [(phase: String, x: Double, y: Double)] = []

    private func driver() -> RemoteInputDriver {
        let sink = RemoteInputEventSink(
            pointerLocation: { CGPoint(x: 50, y: 50) },
            mouseSequence: { _ in true },
            scroll: { _, _, _ in true },
            scrollDetailed: { [weak self] _, x, y, phase in self?.posted.append((phase, x, y)); return true },
            text: { _ in true },
            key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        return driver
    }

    private func scroll(_ phase: String, _ stream: String = "s", y: Double = 0) -> RemoteAction {
        RemoteAction(action: "scroll", x: 0, y: y, interaction: NativeInteraction(token: "t", phase: phase, stream: stream))
    }

    func testFlickPostsGesturePhasesThenMomentumPhases() {
        let input = driver()
        XCTAssertTrue(input.handle(scroll("began", y: 10), upgraded: true, now: 1).accepted)
        XCTAssertTrue(input.handle(scroll("ended"), upgraded: true, now: 1.05).accepted)
        XCTAssertTrue(input.handle(scroll("momentumBegan"), upgraded: true, now: 1.06).accepted)
        XCTAssertTrue(input.handle(scroll("momentumChanged", y: 8), upgraded: true, now: 1.08).accepted)
        XCTAssertTrue(input.handle(scroll("momentumEnded"), upgraded: true, now: 1.2).accepted)
        XCTAssertEqual(posted.map(\.phase), ["began", "ended", "momentumBegan", "momentumChanged", "momentumEnded"])
    }

    func testMomentumWithoutAFinishedGestureIsRefused() {
        let input = driver()
        XCTAssertFalse(input.handle(scroll("momentumBegan"), upgraded: true, now: 1).accepted)
        XCTAssertTrue(input.handle(scroll("began", y: 10), upgraded: true, now: 1).accepted)
        XCTAssertTrue(input.handle(scroll("cancelled"), upgraded: true, now: 1.05).accepted)
        XCTAssertFalse(input.handle(scroll("momentumBegan"), upgraded: true, now: 1.06).accepted,
                       "A cancelled gesture never coasts")
        XCTAssertFalse(input.handle(scroll("momentumBegan"), upgraded: false, now: 1.06).accepted,
                       "Legacy input has no streams")
    }

    func testNewTouchOrOtherInputEndsARunningMomentumFirst() {
        let input = driver()
        _ = input.handle(scroll("began", "a", y: 10), upgraded: true, now: 1)
        _ = input.handle(scroll("ended", "a"), upgraded: true, now: 1.05)
        _ = input.handle(scroll("momentumBegan", "a"), upgraded: true, now: 1.06)
        XCTAssertTrue(input.handle(scroll("began", "b", y: 5), upgraded: true, now: 1.1).accepted)
        XCTAssertEqual(posted.map(\.phase), ["began", "ended", "momentumBegan", "momentumEnded", "began"])
        XCTAssertFalse(input.handle(scroll("momentumChanged", "a", y: 3), upgraded: true, now: 1.12).accepted)

        posted.removeAll()
        _ = input.handle(scroll("ended", "b"), upgraded: true, now: 1.2)
        _ = input.handle(scroll("momentumBegan", "b"), upgraded: true, now: 1.21)
        XCTAssertTrue(input.handle(RemoteAction(action: "click",
            interaction: NativeInteraction(token: "t", clickCount: 1)), upgraded: true, now: 1.3).accepted)
        XCTAssertEqual(posted.map(\.phase), ["ended", "momentumBegan", "momentumEnded"], "A click stops the coast")
    }

    func testStaleMomentumAndSessionResetEndIt() {
        let input = driver()
        _ = input.handle(scroll("began", y: 10), upgraded: true, now: 1)
        _ = input.handle(scroll("ended"), upgraded: true, now: 1.05)
        _ = input.handle(scroll("momentumBegan"), upgraded: true, now: 1.06)
        input.expireMomentum(now: 1.2)
        XCTAssertEqual(posted.last?.phase, "momentumBegan", "Still fresh")
        input.expireMomentum(now: 1.06 + ScrollMomentumGate.idleLimit)
        XCTAssertEqual(posted.last?.phase, "momentumEnded", "A phone that went quiet leaves no coast behind")

        posted.removeAll()
        _ = input.handle(scroll("began", "c", y: 10), upgraded: true, now: 2)
        _ = input.handle(scroll("ended", "c"), upgraded: true, now: 2.05)
        _ = input.handle(scroll("momentumBegan", "c"), upgraded: true, now: 2.06)
        input.resetNativeSequence()
        XCTAssertEqual(posted.last?.phase, "momentumEnded", "Disconnect or a new session ends it")
        XCTAssertNil(input.momentum.active)
    }
}

final class ScrollMomentumGeneratorTests: XCTestCase {
    func testAFlickCoastsAndDecaysToAStop() {
        var momentum = ScrollMomentum()
        for index in 0..<6 {
            momentum.record(CGSize(width: 0, height: 20), at: 1 + Double(index) / 60)
        }
        XCTAssertTrue(momentum.start(at: 1 + 5.0 / 60))
        var deltas: [CGFloat] = []
        var time = 1 + 5.0 / 60
        var ended = false
        for _ in 0..<400 {
            time += 1.0 / 60
            switch momentum.step(at: time) {
            case .changed(let delta)?: deltas.append(delta.height)
            case .ended?: ended = true
            case nil: break
            }
            if ended { break }
        }
        XCTAssertTrue(ended)
        XCTAssertFalse(momentum.isRunning)
        XCTAssertGreaterThan(deltas.first ?? 0, deltas.last ?? 0, "Decelerates")
        XCTAssertTrue(deltas.allSatisfy { $0 >= 0 }, "Keeps the flick's direction")
        XCTAssertLessThanOrEqual(time - (1 + 5.0 / 60), ScrollMomentum.maximumDuration + 0.05)
    }

    func testSlowOrPausedLiftsDoNotCoast() {
        var slow = ScrollMomentum()
        slow.record(CGSize(width: 0, height: 1), at: 1)
        slow.record(CGSize(width: 0, height: 1), at: 1.05)
        XCTAssertFalse(slow.start(at: 1.06))

        var paused = ScrollMomentum()
        paused.record(CGSize(width: 0, height: 30), at: 1)
        paused.record(CGSize(width: 0, height: 30), at: 1.016)
        XCTAssertFalse(paused.start(at: 1.3), "Fingers that stopped before lifting")
    }

    func testCancelReportsOnlyARunningCoastAndSpeedIsCapped() {
        var momentum = ScrollMomentum()
        XCTAssertFalse(momentum.cancel())
        momentum.record(CGSize(width: 900, height: 0), at: 1)
        momentum.record(CGSize(width: 900, height: 0), at: 1.008)
        XCTAssertTrue(momentum.start(at: 1.008))
        XCTAssertLessThanOrEqual(hypot(momentum.velocity!.dx, momentum.velocity!.dy), ScrollMomentum.maximumSpeed + 0.001)
        XCTAssertTrue(momentum.cancel())
        XCTAssertNil(momentum.step(at: 1.1))
    }
}

final class MomentumGestureEngineTests: XCTestCase {
    private final class Recorder {
        var scrolls: [(phase: String, stream: String, delta: CGSize)] = []
        func record(_ command: NativeGestureCommand) -> Bool {
            if case .scroll(let delta, let phase, let stream) = command { scrolls.append((phase, stream, delta)) }
            return true
        }
    }

    private func engine(_ recorder: Recorder, momentum: Bool) -> NativeGestureEngine {
        let engine = NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1,
                                         doubleClickInterval: 0.5) { recorder.record($0) }
        engine.momentumEnabled = momentum
        return engine
    }

    private func flick(_ engine: NativeGestureEngine) {
        for step in 0...6 {
            let y = CGFloat(100 + step * 18)
            engine.update([.init(id: 1, point: CGPoint(x: 0, y: y)), .init(id: 2, point: CGPoint(x: 40, y: y))],
                          at: 1 + Double(step) / 60)
        }
        engine.update([], at: 1 + 6.0 / 60)
    }

    func testAFlickedScrollContinuesItsStreamWithMomentum() {
        let recorder = Recorder(); let input = engine(recorder, momentum: true)
        flick(input)
        XCTAssertEqual(recorder.scrolls.last?.phase, "momentumBegan")
        XCTAssertTrue(input.hasMomentum)
        var time = 1 + 6.0 / 60
        while input.hasMomentum && time < 5 { time += 0.02; input.tick(at: time) }
        let phases = recorder.scrolls.map(\.phase)
        XCTAssertEqual(phases.last, "momentumEnded")
        XCTAssertTrue(phases.contains("momentumChanged"))
        XCTAssertEqual(Set(recorder.scrolls.map(\.stream)).count, 1, "One stream from fingers to coast")
        XCTAssertEqual(phases.firstIndex(of: "ended").map { $0 + 1 }, phases.firstIndex(of: "momentumBegan"))
    }

    func testWithoutTheMacFeatureTheScrollJustStops() {
        let recorder = Recorder(); let input = engine(recorder, momentum: false)
        flick(input)
        XCTAssertEqual(recorder.scrolls.last?.phase, "ended")
        XCTAssertFalse(input.hasMomentum)
    }

    func testANewTouchCancelOrReconfigureStopsTheCoast() {
        let recorder = Recorder(); let input = engine(recorder, momentum: true)
        flick(input)
        input.tick(at: 1.14)
        input.update([.init(id: 3, point: CGPoint(x: 10, y: 10))], at: 1.16)
        XCTAssertEqual(recorder.scrolls.last?.phase, "momentumEnded", "A finger landing catches the page")
        XCTAssertFalse(input.hasMomentum)
        input.update([], at: 1.3)

        let cancelled = Recorder(); let other = engine(cancelled, momentum: true)
        flick(other)
        other.cancel()
        XCTAssertEqual(cancelled.scrolls.last?.phase, "momentumEnded")

        let reconfigured = Recorder(); let third = engine(reconfigured, momentum: true)
        flick(third)
        third.configure(enabled: false, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
        XCTAssertEqual(reconfigured.scrolls.last?.phase, "momentumEnded")
        XCTAssertFalse(third.hasMomentum)
    }
}

// MARK: - iPad mouse Back and Forward (O12)

final class AuxiliaryButtonTests: XCTestCase {
    func testSideButtonsPostTheMacsOtherMouseButtonsThreeAndFour() {
        var posted: [RemoteInputEventSink.MouseEvent] = []
        let sink = RemoteInputEventSink(pointerLocation: { CGPoint(x: 20, y: 30) },
                                        mouseSequence: { posted.append(contentsOf: $0); return true },
                                        scroll: { _, _, _ in true }, text: { _ in true }, key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

        let back = driver.handle(RemoteAction(action: "auxClick", key: "back",
            interaction: NativeInteraction(token: "t", clickCount: 1)), upgraded: true, now: 1)
        XCTAssertTrue(back.accepted)
        XCTAssertEqual(posted.map(\.type), [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(posted.map(\.button.rawValue), [3, 3])
        XCTAssertEqual(back.clickPoint, CGPoint(x: 20, y: 30))

        posted.removeAll()
        XCTAssertTrue(driver.handle(RemoteAction(action: "auxClick", key: "forward")).accepted)
        XCTAssertEqual(posted.map(\.button.rawValue), [4, 4])

        posted.removeAll()
        XCTAssertFalse(driver.handle(RemoteAction(action: "auxClick", key: "sideways")).accepted)
        XCTAssertFalse(driver.handle(RemoteAction(action: "auxClick", key: "back",
            interaction: NativeInteraction(token: "t", clickCount: 2)), upgraded: true, now: 2).accepted)
        XCTAssertTrue(posted.isEmpty)
    }

    func testButtonEnumAndRealEventsCarryTheButtonNumber() {
        XCTAssertEqual(RemoteMouseButton.back.cgButton.rawValue, 3)
        XCTAssertEqual(RemoteMouseButton.forward.cgButton.rawValue, 4)
        XCTAssertEqual(RemoteMouseButton.center.downType, .otherMouseDown)
        XCTAssertEqual(RemoteMouseButton.right.upType, .rightMouseUp)
        XCTAssertEqual(RemoteMouseButton.auxiliary("back"), .back)
        XCTAssertEqual(RemoteMouseButton.auxiliary("forward"), .forward)
        XCTAssertNil(RemoteMouseButton.auxiliary("left"))
        for button in [RemoteMouseButton.back, .forward] {
            let event = CGEvent(mouseEventSource: nil, mouseType: button.downType, mouseCursorPosition: .zero,
                                mouseButton: button.cgButton)
            XCTAssertEqual(event?.getIntegerValueField(.mouseEventButtonNumber), Int64(button.cgButton.rawValue))
        }
    }

    func testProtocolAndPhoneMapping() {
        XCTAssertNoThrow(try RemoteAction(action: "auxClick", key: "back").validate())
        XCTAssertNoThrow(try RemoteAction(action: "auxClick", key: "forward",
            interaction: NativeInteraction(token: "t", clickCount: 1)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "auxClick", key: "menu").validate())
        XCTAssertThrowsError(try RemoteAction(action: "auxClick", key: "back",
            interaction: NativeInteraction(token: "t", clickCount: 2)).validate())
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.auxiliaryButtons))
        XCTAssertEqual(AuxiliaryMouseButton(auxiliaryIndex: 0), .back)
        XCTAssertEqual(AuxiliaryMouseButton(auxiliaryIndex: 1), .forward)
        XCTAssertNil(AuxiliaryMouseButton(auxiliaryIndex: 2))

        let log = CommandLog()
        let router = HardwarePointerRouter(onCommand: { log.record($0) })
        router.auxiliaryClick(.back)
        XCTAssertTrue(log.auxiliary.isEmpty, "A disabled pointer sends nothing")
        router.setEnabled(true)
        router.auxiliaryClick(.back)
        router.auxiliaryClick(.forward)
        XCTAssertEqual(log.auxiliary, [.back, .forward])
    }
}

// MARK: - Private event source (O28)

final class PrivateEventSourceTests: XCTestCase {
    func testFlagDefaultsOnAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "PrivateEventSourceTests")!
        defaults.removePersistentDomain(forName: "PrivateEventSourceTests")
        XCTAssertTrue(RemoteInputEventSource.privateStateEnabled(defaults: defaults))
        defaults.set(false, forKey: RemoteInputEventSource.defaultsKey)
        XCTAssertFalse(RemoteInputEventSource.privateStateEnabled(defaults: defaults))
        defaults.set(true, forKey: RemoteInputEventSource.defaultsKey)
        XCTAssertTrue(RemoteInputEventSource.privateStateEnabled(defaults: defaults))
        defaults.removePersistentDomain(forName: "PrivateEventSourceTests")
        XCTAssertNil(RemoteInputEventSource.make(privateState: false), "Off keeps the shared session state")
    }

    func testEventsFromThePrivateSourceHaveTheirOwnStateAndStayTagged() throws {
        let source = try XCTUnwrap(RemoteInputEventSource.make(privateState: true))
        XCTAssertNotEqual(source.sourceStateID, .combinedSessionState)
        XCTAssertNotEqual(source.sourceStateID, .hidSystemState)
        XCTAssertEqual(source.userData, RemoteInputTag.value)
        let mouse = try XCTUnwrap(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                          mouseCursorPosition: .zero, mouseButton: .left))
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                           wheel1: 1, wheel2: 0, wheel3: 0))
        for event in [mouse, key, scroll] {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceStateID), Int64(source.sourceStateID.rawValue))
            XCTAssertTrue(RemoteInputTag.isInjected(event, ownPID: 1), "Tagged without relying on the PID")
            XCTAssertTrue(event.flags.isDisjoint(with: [.maskShift, .maskCommand, .maskAlternate, .maskControl]),
                          "No modifier state from the physical keyboard")
        }
        RemoteInputTag.mark(key)
        XCTAssertTrue(RemoteInputTag.isInjected(key))
    }
}

// MARK: - Password-field awareness (O5)

final class SecureFocusTests: XCTestCase {
    func testPolicyUsesTheSubroleOrSecureEventInput() {
        XCTAssertTrue(HostSecureFocusPolicy.isSecure(subrole: kAXSecureTextFieldSubrole, secureEventInput: false))
        XCTAssertTrue(HostSecureFocusPolicy.isSecure(subrole: nil, secureEventInput: true))
        XCTAssertTrue(HostSecureFocusPolicy.isSecure(subrole: "AXSearchField", secureEventInput: true))
        XCTAssertFalse(HostSecureFocusPolicy.isSecure(subrole: "AXSearchField", secureEventInput: false))
        XCTAssertFalse(HostSecureFocusPolicy.isSecure(subrole: nil, secureEventInput: false))
        _ = HostSecureFocus.secureEventInputEnabled()
    }

    func testTheFlagTravelsOnlyOnAFocusReply() {
        let probe = String(repeating: "a", count: 32)
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", textFocusProbe: probe, textFocusEditable: true,
                                          textFocusSecure: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusSecure: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusProbe: probe, textFocusSecure: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", textFocusSecure: false).validate())
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.secureFocus))
        let encoded = try! JSONEncoder().encode(RemoteAction(action: "heartbeat", textFocusProbe: probe,
                                                             textFocusEditable: true, textFocusSecure: true))
        let keys = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(keys["textFocusSecure"] as? Bool, true)
        XCTAssertNil(keys["text"].flatMap { ($0 as? String)?.isEmpty == false ? $0 : nil }, "No field content")
    }
}

// MARK: - Colour correctness (O3)

final class StreamColorTests: XCTestCase {
    func testCaptureIsPinnedToSRGBAndBT601() {
        let output = CapturePixelDimensions(width: 1920, height: 1200)
        for region: CaptureRegion? in [nil, CaptureRegion(epoch: 1, x: 0, y: 0, width: 960, height: 600, outputWidth: 960, outputHeight: 600)] {
            let configuration = RemoteCaptureConfiguration.streamConfiguration(
                output: output, region: region, showsCursor: false, fps: 60, displayRefreshHz: 60, tuning: .tuned)
            XCTAssertEqual(configuration.colorSpaceName as String, CGColorSpace.sRGB as String)
            XCTAssertEqual(configuration.colorMatrix as String, CGDisplayStream.yCbCrMatrix_ITU_R_601_4 as String)
            XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    func testTheShippedWebRTCRendererStillAssumesBT601() throws {
        let binary = try XCTUnwrap(Bundle(for: RTCPeerConnectionFactory.self).executableURL)
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        XCTAssertNotNil(data.range(of: Data(StreamColor.rendererShaderExpression.utf8)),
                        "RTCMTLNV12Renderer changed: recheck StreamColor's capture settings")
    }
}

// MARK: - Weak Wi-Fi hint (O6)

final class NetworkLinkHintTests: XCTestCase {
    func testHintsInPriorityOrder() {
        XCTAssertNil(NetworkLinkHint.from(NetworkLinkReading(quality: .good, wifi: true)))
        XCTAssertNil(NetworkLinkHint.from(NetworkLinkReading(quality: .unknown, wifi: true)), "Unknown says nothing")
        XCTAssertNil(NetworkLinkHint.from(NetworkLinkReading(quality: .moderate, wifi: true)))
        XCTAssertEqual(NetworkLinkHint.from(NetworkLinkReading(quality: .minimal, wifi: true))?.title, "Weak Wi-Fi")
        XCTAssertEqual(NetworkLinkHint.from(NetworkLinkReading(quality: .good, expensive: true, cellular: true))?.title,
                       "Cellular / expensive")
        XCTAssertEqual(NetworkLinkHint.from(NetworkLinkReading(quality: .good, expensive: true, wifi: true))?.kind,
                       .cellularOrExpensive, "A hotspot is metered")
        XCTAssertEqual(NetworkLinkHint.from(NetworkLinkReading(quality: .minimal, ultraConstrained: true, wifi: true))?.title,
                       "Very constrained link — picture limited")
        let hint = NetworkLinkHint.from(NetworkLinkReading(quality: .minimal, wifi: true))!
        XCTAssertFalse(hint.detail.isEmpty)
        XCTAssertFalse(hint.nextStep.isEmpty)
    }

    @MainActor
    func testLinkChangesNeverLookLikeAPathChange() {
        let watcher = NetworkPathWatcher()
        var pathChanges = 0
        var hints: [NetworkLinkHint?] = []
        watcher.onChange = { pathChanges += 1 }
        watcher.onLinkChange = { hints.append($0) }
        let signature = NetworkPathSignature(satisfied: true, interfaces: ["en0:wifi"])
        watcher.observe(signature)
        watcher.observeLink(NetworkLinkReading(quality: .good, wifi: true))
        watcher.observe(signature)
        watcher.observeLink(NetworkLinkReading(quality: .minimal, wifi: true))
        watcher.observeLink(NetworkLinkReading(quality: .minimal, wifi: true))
        watcher.observeLink(NetworkLinkReading(quality: .good, wifi: true))
        XCTAssertEqual(pathChanges, 0, "Signaling never reconnects for link quality")
        XCTAssertEqual(hints.map { $0?.kind }, [.weakWiFi, nil])
        XCTAssertNil(watcher.linkHint)
    }
}

// MARK: - Local Network priming (O1)

final class LocalNetworkAccessTests: XCTestCase {
    func testOnlyTheLocalNetworkReasonCountsAsDenied() {
        XCTAssertTrue(LocalNetworkAccess.isDenied(.localNetworkDenied))
        XCTAssertFalse(LocalNetworkAccess.isDenied(.notAvailable))
        XCTAssertFalse(LocalNetworkAccess.isDenied(.wifiDenied))
        XCTAssertFalse(LocalNetworkAccess.isDenied(.cellularDenied))
    }

    func testTriggerHoldsTheProofBackWhileTheAlertAppears() {
        LocalNetworkAccess.triggerAlert(now: 100)
        XCTAssertEqual(LocalNetworkAccess.settleDelay(now: 100.25), LocalNetworkAccess.alertSettleTime - 0.25, accuracy: 0.001)
        XCTAssertEqual(LocalNetworkAccess.settleDelay(now: 102), 0)
        XCTAssertEqual(LocalNetworkAccess.settleDelay(now: 99), 0, "A clock that went backwards never waits")
    }

    @MainActor
    func testTheMacNeverWaits() async {
        let ready = await LocalNetworkAccess.waitUntilForeground(timeout: 0)
        XCTAssertTrue(ready)
        XCTAssertTrue(LocalNetworkAccess.appIsActive)
    }

    func testDeniedStageIsReported() {
        var stage = LocalProofStage()
        XCTAssertFalse(stage.summary.contains("localNetwork=denied"))
        stage.localNetworkDenied = true
        XCTAssertTrue(stage.summary.contains("localNetwork=denied"))
    }
}
