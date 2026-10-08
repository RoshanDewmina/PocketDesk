import CoreGraphics
import XCTest

/// The scroll input path, stage by stage, replaying the 7 Oct device rounds: a 1.2 s, 260 pt two-finger swipe
/// with touches every 1/120 s, on a 1920-pt-wide Mac display shown at fit width on a portrait iPhone 17.
final class ScrollGesturePathTests: XCTestCase {
    static let fitWidthScale: CGFloat = 402.0 / 1920

    private func swipe(steps: Int = 144, duration: TimeInterval = 1.2, travel: CGFloat = 260, liftAfter: TimeInterval = 0.03)
        -> [(time: TimeInterval, phase: String, delta: CGSize)] {
        var now: TimeInterval = 1000
        var sent: [(time: TimeInterval, phase: String, delta: CGSize)] = []
        let engine = NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1,
                                         pointerScale: Self.fitWidthScale, doubleClickInterval: 0.5,
                                         onCommand: { command in
            if case .scroll(let delta, let phase, _) = command { sent.append((now, phase, delta)) }
            return true
        })
        engine.momentumEnabled = true
        engine.hostMomentumEnabled = true
        func fingers(_ dy: CGFloat) -> [NativeGestureEngine.Touch] {
            [.init(id: 1, point: CGPoint(x: 165, y: 567 + dy)), .init(id: 2, point: CGPoint(x: 237, y: 567 + dy))]
        }
        let start = now
        engine.update(fingers(0), at: now)
        for step in 1...steps {
            now = start + 0.03 + duration * Double(step) / Double(steps)
            engine.update(fingers(-travel * CGFloat(step) / CGFloat(steps)), at: now)
        }
        now += liftAfter
        engine.update([], at: now)
        return sent
    }

    func testTheEngineSendsOneScrollPerTouchUpdateAtThatUpdateWithAllItsTravel() throws {
        let sent = swipe()
        let motion = sent.filter { $0.phase == "began" || $0.phase == "changed" }
        XCTAssertEqual(motion.first?.phase, "began")
        XCTAssertEqual(motion.count, 142, "recognised at 5 pt of travel (3 updates), then one message per update")
        XCTAssertEqual(motion.reduce(CGFloat(0)) { $0 + $1.delta.height }, -260 / Self.fitWidthScale, accuracy: 0.001,
                       "no travel is lost: 260 pt over a 0.209 picture is 1 242 Mac points")
        let gaps = zip(motion, motion.dropFirst()).map { $1.time - $0.time }
        XCTAssertEqual(try XCTUnwrap(gaps.max()), 1.2 / 144, accuracy: 1e-9, "nothing is held or coalesced")
        XCTAssertEqual(try XCTUnwrap(motion.last).time - motion[0].time, 1.2 * 141 / 144, accuracy: 1e-9)
        XCTAssertEqual(sent.map(\.phase).suffix(2), ["ended", ScrollMomentumPhase.began.rawValue],
                       "lifted 30 ms after the last move, the swipe hands the Mac a coast")
        XCTAssertGreaterThan(try XCTUnwrap(sent.last).delta.height.magnitude, ScrollMomentum.minimumLiftSpeed)
    }

    /// What the Mac received in every round: 623–624 points per swipe in ~34 messages over ~0.3 s, ended
    /// ~0.27 s after the last one. That is the first half of the path, two path steps per 120 Hz callback, then a pause.
    func testTheRoundsDeliveredHalfThePathAtDoubleSpeedAndLiftedTooLateToCoast() {
        let sent = swipe(steps: 36, duration: 0.3, travel: 130, liftAfter: 0.27)
        let motion = sent.filter { $0.phase == "began" || $0.phase == "changed" }
        XCTAssertEqual(motion.count, 35)
        XCTAssertEqual(motion.reduce(CGFloat(0)) { $0 + $1.delta.height }, -621, accuracy: 1, "the 623 pt Safari logged per swipe")
        XCTAssertEqual(sent.last?.phase, "ended", "a 0.27 s rest before lift leaves no momentum, as in the rounds")
    }
}

@MainActor
final class ScrollSendPathTests: XCTestCase {
    func testEveryScrollMessageLeavesInTheCallThatMadeItOnTheOrderedReliableLane() throws {
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), signaling: ScriptedSignaling())
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), signaling: ScriptedSignaling())
        host.startInputFixtureForTesting(session: "fixture"); phone.startInputFixtureForTesting(session: "fixture")
        host.setHostInputEpoch(7)
        defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())

        let stream = UUID().uuidString
        for index in 0..<144 {
            let before = upstream.count
            let scroll = RemoteAction(action: "scroll", y: -8.62, epoch: 7,
                                      interaction: NativeInteraction(token: "t", phase: index == 0 ? "began" : "changed", stream: stream))
            XCTAssertTrue(phone.sendControl(scroll))
            XCTAssertEqual(upstream.count, before + 1, "no pacing or coalescing on the phone")
        }
        XCTAssertTrue(upstream.allSatisfy { $0.action.action == "scroll" && $0.input?.kind == "barrier" },
                      "scroll is a causal semantic: the reliable, ordered control channel, where one late packet holds every later one")
        XCTAssertEqual(upstream.map(\.sequence), Array(upstream[0].sequence..<(upstream[0].sequence + 144)))

        var semantics: [RemoteAction] = []
        host.onCausalInput = { _, semantic in if let semantic { semantics.append(semantic) } }
        for packet in upstream { try host.receiveInputFixtureForTesting(packet) }
        XCTAssertEqual(semantics.count, 144)
        XCTAssertEqual(semantics.reduce(0.0) { $0 + $1.y }, -8.62 * 144, accuracy: 1e-6)

        var wire = upstream[1]
        wire.session = try SecureRandom.token()
        wire.action.interaction?.token = try SecureRandom.token()
        wire.inputTiming = InputSendTiming(sendHostMs: 1_791_411_239_388.762, uncertaintyMs: 3.3)
        let bytes = try JSONEncoder().encode(wire).count
        XCTAssertTrue((500...900).contains(bytes), "each 120 Hz scroll message is \(bytes) bytes of JSON")
    }
}

final class ScrollPostingPathTests: XCTestCase {
    /// The first swipe of the 7 Oct event-tap capture (`auto-ab/wtap.txt`): ms after the first event and the
    /// posted point delta. Eight on time, a 109 ms hole, then thirteen messages within 3 ms.
    static let tapMs: [Double] = [0, 0, 1, 7, 16, 39, 40, 54, 163, 163, 164, 164, 164, 164, 164, 165, 166, 166, 166, 166, 166,
                                  190, 199, 210, 216, 216, 228, 233, 254, 255, 262, 267, 288, 300]
    static let tapDeltas: [Double] = [-53, -8, -25, -10, -16, -10, -60, -43, -8, -10, -8, -8, -27, -8, -25, -10, -25, -8, -10,
                                      -8, -35, -35, -8, -18, -8, -27, -8, -8, -10, -35, -8, -25, -10, -8]

    private var posted: [(time: TimeInterval, phase: String, y: Double)] = []
    private var moved: [RemoteInputEventSink.MouseEvent] = []
    private var clock: TimeInterval = 0
    private var cursor = CGPoint(x: 50, y: 50)

    private func driver(smoothing: Bool = false, targetsStream: Bool = false) -> RemoteInputDriver {
        let sink = RemoteInputEventSink(
            pointerLocation: { [unowned self] in cursor },
            mouseSequence: { [unowned self] events in moved.append(contentsOf: events); return true },
            scroll: { [unowned self] _, _, y in posted.append((clock, "legacy", y)); return true },
            scrollDetailed: { [unowned self] _, _, y, phase in posted.append((clock, phase, y)); return true },
            text: { _ in true }, key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, scrollSmoothing: smoothing, scrollTargetsStream: targetsStream,
                                       isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        return driver
    }

    private func scroll(_ phase: String, y: Double = 0, stream: String = "s") -> RemoteAction {
        RemoteAction(action: "scroll", y: y, interaction: NativeInteraction(token: "t", phase: phase, stream: stream))
    }

    /// Replays the capture at its arrival times, stepping the driver every 1/240 s in between as the executor's timer would.
    private func replay(_ input: RemoteInputDriver) {
        clock = 1
        XCTAssertTrue(input.handle(scroll("began", y: Self.tapDeltas[0]), upgraded: true, now: clock).accepted)
        var tick = clock
        for (ms, delta) in zip(Self.tapMs, Self.tapDeltas).dropFirst() {
            let arrival = 1 + ms / 1000
            while tick + ScrollPacer<Void>.spacing <= arrival {
                tick += ScrollPacer<Void>.spacing; clock = tick
                input.stepPacedScroll(now: tick)
            }
            clock = arrival
            XCTAssertTrue(input.handle(scroll("changed", y: delta), upgraded: true, now: arrival).accepted)
        }
        while input.hasPacedScroll { tick = max(tick, clock) + ScrollPacer<Void>.spacing; clock = tick; input.stepPacedScroll(now: tick) }
    }

    /// The largest scroll posted within one 60 Hz frame of the Mac's display, after the swipe's first 100 ms.
    private func largestFrameStepAfterTheHole() -> Double {
        let late = posted.filter { $0.time >= 1.1 }
        var largest = 0.0
        for start in late {
            var step = 0.0
            for post in late where post.time >= start.time && post.time < start.time + 1.0 / 60 - 1e-6 { step += abs(post.y) }
            largest = max(largest, step)
        }
        return largest
    }

    func testTodayEveryArrivalPostsAtOnceSoAHeldBurstLandsInOneFrame() {
        replay(driver())
        XCTAssertEqual(posted.count, 34)
        var worst = 0.0
        for (post, ms) in zip(posted, Self.tapMs) { worst = max(worst, abs((post.time - 1) * 1000 - ms)) }
        XCTAssertEqual(worst, 0, accuracy: 1e-6, "the Mac posts each message the moment it lands")
        XCTAssertEqual(largestFrameStepAfterTheHole(), 190, "the thirteen held messages move the page 190 points in one frame")
    }

    func testSmoothingGlidesTheBurstAtTwiceTheTouchCadenceAndKeepsEveryPoint() throws {
        replay(driver(smoothing: true))
        XCTAssertEqual(posted.reduce(0.0) { $0 + $1.y }, Self.tapDeltas.reduce(0, +), accuracy: 1e-9, "nothing is dropped")
        XCTAssertLessThanOrEqual(largestFrameStepAfterTheHole(), 100, "the 190-point jump becomes a glide: 96 points at most in any frame")
        let glide = Set(posted.filter { $0.time >= 1.163 && $0.time < 1.22 }.map(\.time))
        XCTAssertGreaterThanOrEqual(glide.count, 12, "one release per 1/240 s tick")
        // Never ahead of the phone, never more than the hold cap (plus one tick) behind it.
        let lag: TimeInterval = ScrollPacer<Void>.maximumHold + ScrollPacer<Void>.spacing
        func arrived(by time: TimeInterval) -> Double {
            var sum = 0.0
            for (ms, delta) in zip(Self.tapMs, Self.tapDeltas) where 1 + ms / 1000 <= time + 1e-9 { sum += delta }
            return sum
        }
        func postedBy(_ time: TimeInterval) -> Double {
            var sum = 0.0
            for post in posted where post.time <= time { sum += post.y }
            return sum
        }
        for post in posted {
            XCTAssertGreaterThanOrEqual(postedBy(post.time), arrived(by: post.time) - 1e-9, "never ahead of the phone")
            XCTAssertLessThanOrEqual(postedBy(post.time), arrived(by: post.time - lag) + 1e-9, "never more than the cap behind")
        }
        let lastTwo: [TimeInterval] = posted.suffix(2).map { $0.time }
        let expected: [TimeInterval] = [1 + 288.0 / 1000, 1 + 300.0 / 1000]
        XCTAssertEqual(lastTwo, expected, "caught up: later messages post as they land")
    }

    func testAnotherInputOrTheGestureEndPostsHeldScrollFirst() {
        let input = driver(smoothing: true)
        clock = 1
        XCTAssertTrue(input.handle(scroll("began", y: -10), upgraded: true, now: 1).accepted)
        for _ in 0..<5 { XCTAssertTrue(input.handle(scroll("changed", y: -8), upgraded: true, now: 1.1).accepted) }
        XCTAssertTrue(input.hasPacedScroll)
        XCTAssertTrue(input.handle(scroll("ended"), upgraded: true, now: 1.101).accepted)
        XCTAssertEqual(posted.map(\.phase), ["began", "changed"], "the end waits behind the held changes")
        XCTAssertTrue(input.hasPacedScroll)
        XCTAssertFalse(input.stepPacedScroll(now: 1.2))
        XCTAssertEqual(posted.map(\.phase), ["began", "changed", "changed", "ended"], "held changes merge and post before the end")
        XCTAssertEqual(posted.map(\.y), [-10, -8, -32, 0])
        XCTAssertFalse(input.hasPacedScroll)

        posted.removeAll()
        XCTAssertTrue(input.handle(scroll("began", y: -10, stream: "t"), upgraded: true, now: 2).accepted)
        for _ in 0..<3 { _ = input.handle(scroll("changed", y: -8, stream: "t"), upgraded: true, now: 2.1) }
        XCTAssertTrue(input.handle(RemoteAction(action: "click", interaction: NativeInteraction(token: "t", clickCount: 1)),
                                   upgraded: true, now: 2.101).accepted)
        XCTAssertEqual(posted.map(\.y), [-10, -8, -16], "a click never overtakes scroll that arrived before it")
        XCTAssertEqual(moved.map(\.type), [.leftMouseDown, .leftMouseUp])

        posted.removeAll()
        XCTAssertTrue(input.handle(scroll("began", y: -1, stream: "u"), upgraded: true, now: 3).accepted)
        _ = input.handle(scroll("changed", y: -1, stream: "u"), upgraded: true, now: 3.1)
        _ = input.handle(scroll("changed", y: -1, stream: "u"), upgraded: true, now: 3.1)
        XCTAssertTrue(input.handle(scroll("changed", stream: "u"), upgraded: true, now: 3.101).accepted)
        XCTAssertTrue(input.hasPacedScroll, "a resting-finger keep-alive neither posts nor flushes")
    }

    func testHeldScrollIsDroppedWithControlOrTheSession() {
        let input = driver(smoothing: true)
        XCTAssertTrue(input.handle(scroll("began", y: -10), upgraded: true, now: 1).accepted)
        for _ in 0..<4 { _ = input.handle(scroll("changed", y: -8), upgraded: true, now: 1.1) }
        input.enabled = false
        XCTAssertFalse(input.stepPacedScroll(now: 1.2))
        XCTAssertFalse(input.hasPacedScroll)
        XCTAssertEqual(posted.count, 2, "control off posts nothing more")

        let reset = driver(smoothing: true)
        posted.removeAll()
        XCTAssertTrue(reset.handle(scroll("began", y: -10), upgraded: true, now: 1).accepted)
        for _ in 0..<4 { _ = reset.handle(scroll("changed", y: -8), upgraded: true, now: 1.1) }
        reset.resetNativeSequence()
        XCTAssertFalse(reset.hasPacedScroll, "a new session or geometry drops scroll aimed at the old one")
        XCTAssertFalse(reset.stepPacedScroll(now: 1.2))
    }

    func testLegacyScrollAndSmoothingOffAreUnchanged() {
        let input = driver(smoothing: true)
        for _ in 0..<5 { XCTAssertTrue(input.handle(RemoteAction(action: "scroll", y: -8), upgraded: false, now: 1).accepted) }
        XCTAssertFalse(input.hasPacedScroll, "an old phone's unphased scroll posts as it lands")
        let off = driver()
        XCTAssertTrue(off.handle(scroll("began", y: -10), upgraded: true, now: 2).accepted)
        for _ in 0..<5 { XCTAssertTrue(off.handle(scroll("changed", y: -8), upgraded: true, now: 2.1).accepted) }
        XCTAssertFalse(off.hasPacedScroll)
        XCTAssertEqual(posted.map(\.phase), Array(repeating: "legacy", count: 5) + ["began"] + Array(repeating: "changed", count: 5))
    }

    /// A listen-only tap saw the phone's scrolls at (1739, -571) on the external display above the streamed one:
    /// macOS delivers a scroll under the real cursor, whatever location the event carries.
    func testScrollOnStreamFirstMovesAnOffDisplayCursorOntoTheStreamedDisplay() {
        cursor = CGPoint(x: 80, y: -571)
        let input = driver(targetsStream: true)
        XCTAssertTrue(input.handle(scroll("began", y: -10), upgraded: true, now: 1).accepted)
        XCTAssertEqual(moved.map(\.type), [.mouseMoved])
        XCTAssertEqual(moved.first?.point, CGPoint(x: 80, y: 0), "onto the streamed display's nearest edge, where the scroll aims")
        cursor = CGPoint(x: 80, y: 0)
        XCTAssertTrue(input.handle(scroll("changed", y: -8), upgraded: true, now: 1.01).accepted)
        XCTAssertEqual(moved.count, 1, "only a gesture's start places the cursor")

        moved.removeAll()
        cursor = CGPoint(x: 40, y: 40)
        let inside = driver(targetsStream: true)
        XCTAssertTrue(inside.handle(scroll("began", y: -10, stream: "v"), upgraded: true, now: 2).accepted)
        XCTAssertTrue(moved.isEmpty, "a cursor already on the streamed display stays put")

        cursor = CGPoint(x: 80, y: -571)
        let off = driver()
        XCTAssertTrue(off.handle(scroll("began", y: -10, stream: "w"), upgraded: true, now: 3).accepted)
        XCTAssertTrue(moved.isEmpty, "switch off: today's behaviour")

        let legacy = driver(targetsStream: true)
        XCTAssertTrue(legacy.handle(RemoteAction(action: "scroll", y: -8), upgraded: false, now: 4).accepted)
        XCTAssertEqual(moved.map(\.type), [.mouseMoved], "an old phone's scroll is placed too")
    }
}

final class ScrollPacerTests: XCTestCase {
    func testOnTimeMessagesPassAndABurstIsSpacedHeldNoLongerThanTheCap() {
        var pacer = ScrollPacer<Int>()
        for index in 0..<10 { XCTAssertEqual(pacer.offer(index, at: Double(index) / 120), [index]) }
        XCTAssertTrue(pacer.isEmpty)

        let burst = 1.0
        XCTAssertEqual(pacer.offer(100, at: burst), [100])
        for index in 101..<120 { XCTAssertEqual(pacer.offer(index, at: burst), []) }
        var released: [(Int, Double)] = []
        var now = burst
        while !pacer.isEmpty { now += 0.001; released += pacer.release(at: now).map { ($0, now) } }
        XCTAssertEqual(released.map(\.0), Array(101..<120), "order is kept")
        XCTAssertEqual(released[0].1, burst + ScrollPacer<Int>.spacing, accuracy: 0.0011)
        XCTAssertEqual(released.last!.1, burst + ScrollPacer<Int>.maximumHold, accuracy: 0.0011,
                       "nineteen held messages would need 79 ms; none waits past the cap")
    }

    func testFlushHandsOverEverythingAndRestartsTheSpacingFromNow() {
        var pacer = ScrollPacer<Int>()
        XCTAssertEqual(pacer.offer(1, at: 1), [1])
        XCTAssertEqual(pacer.offer(2, at: 1), [])
        XCTAssertEqual(pacer.offer(3, at: 1), [])
        XCTAssertEqual(pacer.flush(at: 1.001), [2, 3])
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertEqual(pacer.offer(4, at: 1.001 + ScrollPacer<Int>.spacing), [4])
        XCTAssertEqual(pacer.offer(5, at: .nan), [5], "a bad clock never holds input")
        XCTAssertEqual(pacer.offer(6, at: 2), [6])
        XCTAssertEqual(pacer.offer(7, at: 2), [])
        pacer.discard()
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertEqual(pacer.release(at: 3), [])
    }
}

final class ScrollSmoothingExecutorTests: XCTestCase {
    private let clockLock = NSLock()
    private var frozen: TimeInterval = 0
    private var now: TimeInterval {
        get { clockLock.lock(); defer { clockLock.unlock() }; return frozen }
        set { clockLock.lock(); frozen = newValue; clockLock.unlock() }
    }

    /// The executor's timer is real; its clock is the test's, so nothing is due until the test says so.
    private func makeExecutor(_ record: @escaping (String, Double) -> Void) -> HostInputExecutor {
        let sink = RemoteInputEventSink(
            pointerLocation: { CGPoint(x: 50, y: 50) }, mouseSequence: { _ in true }, scroll: { _, _, _ in true },
            scrollDetailed: { _, _, y, phase in record(phase, y); return true },
            text: { _ in true }, key: { _, _ in true })
        let executor = HostInputExecutor(driver: RemoteInputDriver(eventSink: sink, scrollSmoothing: true, isTrusted: { true }),
                                         clock: { [unowned self] in now })
        executor.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)); executor.enabled = true
        return executor
    }

    private func scroll(_ phase: String, y: Double = 0) -> RemoteAction {
        RemoteAction(action: "scroll", y: y, interaction: NativeInteraction(token: "t", phase: phase, stream: "s"))
    }

    func testTheExecutorsTimerReleasesAHeldBurst() {
        let lock = NSLock()
        var total = 0.0, events = 0
        let drained = expectation(description: "the timer posts the whole burst")
        drained.assertForOverFulfill = false
        let executor = makeExecutor { _, y in
            lock.lock(); total += y; events += 1; let done = total <= -90; lock.unlock()
            if done { drained.fulfill() }
        }
        now = 100
        XCTAssertTrue(executor.handle(scroll("began", y: -10), upgraded: true, now: now).accepted)
        for _ in 0..<10 { XCTAssertTrue(executor.handle(scroll("changed", y: -8), upgraded: true, now: now).accepted) }
        XCTAssertTrue(executor.hasPacedScroll)
        lock.lock(); XCTAssertEqual(total, -18, "began and the first change post at once"); lock.unlock()
        now = 100.1
        wait(for: [drained], timeout: 2)
        executor.drain()
        lock.lock(); XCTAssertEqual(total, -90); XCTAssertGreaterThan(events, 2); lock.unlock()
        XCTAssertFalse(executor.hasPacedScroll)
    }

    func testControlOffDropsTheHeldBurst() {
        let lock = NSLock()
        var total = 0.0
        let executor = makeExecutor { _, y in lock.lock(); total += y; lock.unlock() }
        now = 100
        XCTAssertTrue(executor.handle(scroll("began", y: -10), upgraded: true, now: now).accepted)
        for _ in 0..<10 { XCTAssertTrue(executor.handle(scroll("changed", y: -8), upgraded: true, now: now).accepted) }
        executor.enabled = false
        XCTAssertFalse(executor.hasPacedScroll)
        now = 100.1
        let quiet = expectation(description: "nothing more is posted")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 0.15)
        executor.drain()
        lock.lock(); XCTAssertEqual(total, -18, "control off drops what was held"); lock.unlock()
    }
}

final class ScrollPathSwitchTests: XCTestCase {
    func testSmoothingDefaultsOnTargetingDefaultsOffBothAreListedAndNamedInTheSummary() {
        let suite = "scroll-input-path-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).scrollSmoothing, "on by default since the 8 Oct 2026 device A/B")
        XCTAssertFalse(StreamTuning.resolve(defaults: defaults).scrollTargetsStream)
        XCTAssertTrue(StreamTuning.tuned.summary.contains("scroll smoothing"))
        XCTAssertFalse(StreamTuning.tuned.summary.contains("scroll on stream"))
        XCTAssertFalse(StreamTuning.legacy.scrollSmoothing, "previous tuning posts every scroll on arrival")
        defaults.set(false, forKey: StreamTuning.scrollSmoothingKey)
        let off = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(off.scrollSmoothing, "NO turns smoothing off")
        XCTAssertFalse(off.summary.contains("scroll smoothing"))
        defaults.set(true, forKey: StreamTuning.scrollSmoothingKey)
        defaults.set(true, forKey: StreamTuning.scrollTargetsStreamKey)
        let on = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(on.scrollSmoothing)
        XCTAssertTrue(on.scrollTargetsStream)
        XCTAssertTrue(on.summary.contains("scroll smoothing"))
        XCTAssertTrue(on.summary.contains("scroll on stream"))
        for key in [StreamTuning.scrollSmoothingKey, StreamTuning.scrollTargetsStreamKey] {
            XCTAssertTrue(StreamTuning.experimentKeys.contains(key), key)
        }
    }

    func testPhoneScrollCadenceReachesTheStatsAndDrains() throws {
        let counters = StreamCounters(phoneRenderTimingEnabled: true)
        for index in 1...30 {
            counters.phoneRenderTiming(.scrollSendInterval, milliseconds: index == 30 ? 109 : 8.3)
            counters.phoneRenderTiming(.scrollStep, milliseconds: 17)
        }
        var snapshot = counters.drain(inputBufferedBytes: nil)
        snapshot.interval = 1
        let report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertEqual(report.scrollSendIntervalP50Ms, 8.3)
        XCTAssertEqual(report.scrollSendIntervalMaxMs, 109)
        XCTAssertEqual(report.scrollSendSamples, 30)
        XCTAssertEqual(report.scrollStepP50, 17)
        XCTAssertEqual(try JSONDecoder().decode(StreamStatsReport.self, from: JSONEncoder().encode(report)), report)
        XCTAssertNil(counters.drain(inputBufferedBytes: nil).scrollSendSamples)
    }
}
