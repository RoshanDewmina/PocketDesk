import XCTest
import AppKit

private final class ExecutorSink {
    var pointer = CGPoint(x: 100, y: 100)
    var events: [RemoteInputEventSink.MouseEvent] = []
    var keys: [CGKeyCode] = []
    var refuse = false
    var beforeMouse: (() -> Void)?
    var sink: RemoteInputEventSink {
        RemoteInputEventSink(pointerLocation: { self.pointer }, mouseSequence: { events in
            self.beforeMouse?()
            guard !self.refuse else { return false }
            self.events += events; self.pointer = events.last?.point ?? self.pointer; return true
        }, scroll: { _, _, _ in true }, text: { _ in true }, key: { key, _ in self.keys.append(key); return true })
    }
    func executor(queue: DispatchQueue = DispatchQueue(label: "input-test"), clock: @escaping () -> TimeInterval = { 10 }) -> HostInputExecutor {
        let result = HostInputExecutor(driver: RemoteInputDriver(eventSink: sink, isTrusted: { true }), queue: queue, clock: clock)
        result.configure(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)); result.enabled = true
        return result
    }
}
final class HostInputExecutorTests: XCTestCase {
    private let authority: (@escaping () -> RemoteInputOutcome) -> RemoteInputOutcome = { $0() }
    private func context(_ moves: [Double] = []) -> InputCausalEnvelope {
        InputCausalEnvelope(kind: "barrier", nonce: String(repeating: "a", count: 32), anchor: String(repeating: "b", count: 32), epoch: 7, applied: UInt64(moves.count),
                            segments: moves.enumerated().map { InputMotionSegment(ordinal: UInt64($0.offset + 1), action: RemoteAction(action: "move", x: $0.element, epoch: 7)) })
    }
    private func admitted(_ action: RemoteAction) -> HostInputExecutor.Admitted { .init(action: action, upgraded: true, expires: 11) }
    func testReliableClickPostsMissingClampedPathAndLateDuplicateDoesNotMoveAgain() {
        let sink = ExecutorSink(), executor = sink.executor(), prefix = context([500, -80])
        executor.beginCausalContext(context())
        let click = RemoteAction(action: "click", epoch: 7, interaction: NativeInteraction(clickCount: 1))
        let done = expectation(description: "click after state")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: admitted(click), routeAuthority: authority) { receipt in
            XCTAssertFalse(receipt.failed); XCTAssertEqual(receipt.applied, 2); done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.events.count, 4)
        for (event, expected) in zip(sink.events, [200.0, 120.0, 120.0, 120.0]) {
            XCTAssertEqual(event.point.x, expected, accuracy: 0.000001)
        }
        let duplicate = expectation(description: "duplicate")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: nil, routeAuthority: authority) { receipt in
            XCTAssertFalse(receipt.failed); XCTAssertTrue(receipt.results.isEmpty); duplicate.fulfill()
        }
        wait(for: [duplicate], timeout: 2)
        XCTAssertEqual(sink.events.count, 4)
    }
    private final class PeerRoute { var media: PeerMedia? }
    /// 20260930.8 host crash: the control-channel post read a destroyed weak `PeerMedia` capture.
    @MainActor
    func testAdmittedInputOnTheLivePeerRouteIsSubmittedAndItsReceiptDelivered() {
        let sink = ExecutorSink(), executor = sink.executor()
        let peer = PeerMedia(isHost: true, servers: []), route = PeerRoute()
        route.media = peer
        var reachedExecutor = false
        let delivered = expectation(description: "receipt delivered on the live route")
        let submitted = executor.post(owner: route, peer: peer, isLive: { $0.media === $1 }, submit: { authority, completion in
            reachedExecutor = true
            return executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: .infinity,
                                   routeAuthority: authority, completion: completion)
        }, deliver: { (owner: PeerRoute, receipt: HostInputExecutor.Receipt) in
            XCTAssertTrue(owner.media === peer)
            XCTAssertTrue(executor.accepts(receipt))
            XCTAssertFalse(receipt.outcome.accepted, "a peer without an open input channel must refuse the post")
            delivered.fulfill()
        })
        XCTAssertTrue(submitted)
        XCTAssertTrue(reachedExecutor)
        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(sink.keys.isEmpty)
    }
    @MainActor
    func testReceiptForAReplacedPeerRouteIsNotDelivered() {
        let sink = ExecutorSink(), executor = sink.executor()
        let peer = PeerMedia(isHost: true, servers: []), route = PeerRoute()
        route.media = peer
        let completed = expectation(description: "executor completed")
        let delivered = expectation(description: "stale receipt delivered")
        delivered.isInverted = true
        XCTAssertTrue(executor.post(owner: route, peer: peer, isLive: { $0.media === $1 }, submit: { authority, completion in
            executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: .infinity, routeAuthority: authority) { receipt in
                completion(receipt); completed.fulfill()
            }
        }, deliver: { (_: PeerRoute, _: HostInputExecutor.Receipt) in delivered.fulfill() }))
        route.media = PeerMedia(isHost: true, servers: [])
        wait(for: [completed, delivered], timeout: 0.5)
    }
    func testRevocationWhileQueuedPreventsPostingAndCompletionCannotRestoreAuthority() {
        let queue = DispatchQueue(label: "blocked-input"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        queue.suspend()
        let done = expectation(description: "rejected")
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: .infinity, routeAuthority: authority) { receipt in
            XCTAssertFalse(receipt.outcome.accepted); XCTAssertFalse(executor.accepts(receipt)); done.fulfill()
        }
        executor.enabled = false
        queue.resume(); wait(for: [done], timeout: 2)
        XCTAssertTrue(sink.keys.isEmpty)
    }
    @MainActor
    func testQueuedHoldGeometryAnchorCancelsDownAndRefusesRetiredCleanupWithoutDisconnect() throws {
        let queue = DispatchQueue(label: "geometry-hold"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), signaling: ScriptedSignaling())
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), signaling: ScriptedSignaling())
        host.startInputFixtureForTesting(session: "geometry"); phone.startInputFixtureForTesting(session: "geometry")
        defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        host.onCausalContext = { context in executor.release(); executor.resetNativeSequence(); executor.beginCausalContext(context) }
        host.setHostInputEpoch(7); phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst()); executor.drain()
        queue.suspend()
        let done = expectation(description: "retired queued down")
        host.onCausalInput = { context, action in
            guard let action else { return }
            executor.submitCausal(context, steps: [], semantic: self.admitted(action), routeAuthority: self.authority) { receipt in
                XCTAssertFalse(receipt.results.contains { $0.1.outcome.accepted }); done.fulfill()
            }
        }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "dragDown", epoch: 7, interaction: NativeInteraction(hold: "old", clickCount: 1))))
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        XCTAssertEqual(executor.releaseScope(for: RemoteAction(action: "release")), "old")
        // A release was sent before the new anchor reached the phone, but reaches
        // the host after its geometry advanced. It must neither post nor disconnect.
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "release", epoch: 7, interaction: NativeInteraction(hold: "old"))))
        let retiredRelease = upstream.removeFirst()
        host.setHostInputEpoch(8)
        XCTAssertNil(executor.releaseScope(for: RemoteAction(action: "release")))
        var rejected = 0; host.onCausalRejected = { _ in rejected += 1 }
        XCTAssertNoThrow(try host.receiveInputFixtureForTesting(retiredRelease)); XCTAssertEqual(rejected, 1)
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        XCTAssertFalse(phone.sendControl(RemoteAction(action: "release", epoch: 7, interaction: NativeInteraction(hold: "old"))))
        XCTAssertFalse(phone.sendInputMoves([RemoteAction(action: "move", x: 5, epoch: 7)]))
        XCTAssertTrue(upstream.isEmpty); XCTAssertTrue(host.connected); XCTAssertTrue(phone.connected)
        queue.resume(); wait(for: [done], timeout: 2); executor.drain()
        XCTAssertFalse(executor.held); XCTAssertTrue(sink.events.isEmpty)
        var newActions: [RemoteAction] = []; host.onCausalInput = { _, action in if let action { newActions.append(action) } }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 8)))
        try host.receiveInputFixtureForTesting(upstream.removeFirst()); XCTAssertEqual(newActions.map(\.key), ["a"])
    }
    func testPostingPermissionDropAfterAdmissionIsRecheckedByDriver() {
        let queue = DispatchQueue(label: "permission-drop"), sink = ExecutorSink()
        var trusted = true
        let executor = HostInputExecutor(driver: RemoteInputDriver(eventSink: sink.sink, isTrusted: { trusted }), queue: queue)
        executor.configure(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)); executor.enabled = true
        queue.suspend()
        let done = expectation(description: "permission refused")
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: .infinity, routeAuthority: authority) { receipt in
            XCTAssertFalse(receipt.outcome.accepted); done.fulfill()
        }
        executor.withAuthority { trusted = false }
        queue.resume(); wait(for: [done], timeout: 2)
        XCTAssertTrue(sink.keys.isEmpty)
    }
    func testDeadlineAndRouteAreCheckedAfterQueueDelay() {
        let sink = ExecutorSink(), executor = sink.executor()
        let done = expectation(description: "expired")
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: 9, routeAuthority: { _ in XCTFail("expired must not reach route"); return RemoteInputOutcome() }) { receipt in
            XCTAssertFalse(receipt.outcome.accepted); done.fulfill()
        }
        wait(for: [done], timeout: 2)
        let cut = expectation(description: "route cut")
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: 11, routeAuthority: { _ in RemoteInputOutcome() }) { receipt in
            XCTAssertFalse(receipt.outcome.accepted); cut.fulfill()
        }
        wait(for: [cut], timeout: 2); XCTAssertTrue(sink.keys.isEmpty)
    }
    func testCopyPreparationReservesFIFOAndDoesNotBlockRevocation() {
        let sink = ExecutorSink(), executor = sink.executor(), baseline = DispatchGroup()
        baseline.enter()
        let done = expectation(description: "two keys"); done.expectedFulfillmentCount = 2
        executor.submit(RemoteAction(action: "key", key: "c"), upgraded: false, expires: 11, preparation: baseline, routeAuthority: authority) { _ in done.fulfill() }
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: 11, routeAuthority: authority) { _ in done.fulfill() }
        XCTAssertTrue(sink.keys.isEmpty)
        baseline.leave(); wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.keys, [8, 0])
    }
    func testQueuedHoldReleaseCancelsBeforeMouseDownAndWrongHoldCannotOwnScope() {
        let queue = DispatchQueue(label: "release-input"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        queue.suspend()
        let down = RemoteAction(action: "dragDown", interaction: NativeInteraction(hold: "pending", clickCount: 1))
        let done = expectation(description: "cancelled down")
        executor.submit(down, upgraded: true, expires: 11, routeAuthority: authority) { result in XCTAssertFalse(result.outcome.accepted); done.fulfill() }
        XCTAssertEqual(executor.releaseScope(for: RemoteAction(action: "release", interaction: NativeInteraction(hold: "wrong"))), "pending")
        XCTAssertEqual(executor.releaseScope(for: RemoteAction(action: "release", interaction: NativeInteraction(hold: "pending"))), "pending")
        executor.invalidateQueued(); executor.release()
        queue.resume(); wait(for: [done], timeout: 2)
        XCTAssertTrue(sink.events.isEmpty); XCTAssertFalse(executor.held)
    }
    func testPhysicalInterventionAndSinkFailureRefuseSemanticAndDoNotAcknowledgeUnpostedState() {
        let sink = ExecutorSink(), executor = sink.executor(), prefix = context([2])
        executor.beginCausalContext(context()); executor.drain(); sink.pointer.x = 50
        let intervention = expectation(description: "physical intervention")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: admitted(RemoteAction(action: "key", key: "a")), routeAuthority: authority) { result in
            XCTAssertTrue(result.intervention); XCTAssertTrue(result.failed); XCTAssertEqual(result.applied, 0); intervention.fulfill()
        }
        wait(for: [intervention], timeout: 2); XCTAssertTrue(sink.keys.isEmpty)
        executor.beginCausalContext(context()); sink.refuse = true
        let rejected = expectation(description: "sink refused")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: admitted(RemoteAction(action: "key", key: "a")), routeAuthority: authority) { result in
            XCTAssertTrue(result.failed); XCTAssertFalse(result.intervention); XCTAssertEqual(result.applied, 0); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2); XCTAssertTrue(sink.keys.isEmpty)
    }
    func testNewEpochCancelsQueuedOldCheckpointWithoutMainQueueDrain() {
        let queue = DispatchQueue(label: "epoch-input"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        executor.beginCausalContext(context()); queue.suspend()
        let prefix = context([3]), done = expectation(description: "old epoch cancelled")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: nil, routeAuthority: authority) { result in XCTAssertTrue(result.failed); done.fulfill() }
        var next = context(); next.epoch = 8; next.anchor = String(repeating: "c", count: 32)
        executor.beginCausalContext(next)
        queue.resume(); wait(for: [done], timeout: 2); XCTAssertTrue(sink.events.isEmpty)
    }
    @MainActor
    func testRejectedExecutorCheckpointRebasesOnlyCurrentPeerAndFreshInputStillPosts() throws {
        for rejection in ["expired", "disabled", "driver", "lease"] {
            let sink = ExecutorSink()
            var now: TimeInterval = 10
            let executor = sink.executor(clock: { now })
            let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), signaling: ScriptedSignaling())
            let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), signaling: ScriptedSignaling())
            host.startInputFixtureForTesting(session: "recover"); phone.startInputFixtureForTesting(session: "recover")
            defer { host.stop(); phone.stop() }
            var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
            host.inputPacketSenderForTesting = { downstream.append($0); return true }
            phone.inputPacketSenderForTesting = { upstream.append($0); return true }
            host.onCausalRecovery = { executor.invalidateQueued(); _ = executor.release(); executor.cancelLease() }
            host.onCausalContext = { executor.beginCausalContext($0) }
            host.setHostInputEpoch(7); phone.requestCausalInput(epoch: 7)
            try host.receiveInputFixtureForTesting(upstream.removeFirst())
            try phone.receiveInputFixtureForTesting(downstream.removeFirst()); executor.drain()
            if rejection == "lease" {
                let hold = expectation(description: "leased hold")
                executor.submit(RemoteAction(action: "dragDown", epoch: 7, interaction: NativeInteraction(hold: "lease", clickCount: 1)),
                                upgraded: true, expires: 100, routeAuthority: authority) { receipt in
                    XCTAssertTrue(receipt.outcome.accepted); hold.fulfill()
                }
                wait(for: [hold], timeout: 2); now = 100
            }
            if rejection == "disabled" { executor.enabled = false }
            if rejection == "driver" { sink.refuse = true }
            XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 3, epoch: 7)]))
            let oldAnchor = try XCTUnwrap(upstream.first?.input?.anchor)
            let rejected = expectation(description: "checkpoint \(rejection)")
            host.onCausalInput = { context, semantic in
                let deadline: TimeInterval = rejection == "expired" ? now : now + 1
                XCTAssertTrue(executor.submitCausal(context, steps: context.segments.map { .init(action: $0.action, upgraded: true, expires: deadline) },
                    semantic: nil, routeAuthority: self.authority) { receipt in
                    XCTAssertTrue(receipt.failed)
                    XCTAssertTrue(host.recoverCausalInput(context)); rejected.fulfill()
                })
            }
            try host.receiveInputFixtureForTesting(upstream.removeFirst())
            wait(for: [rejected], timeout: 2); executor.drain()
            XCTAssertTrue(host.connected); XCTAssertTrue(host.hostRegistered); XCTAssertTrue(host.isRunning)
            XCTAssertFalse(executor.held)
            let anchor = try XCTUnwrap(downstream.first?.input)
            XCTAssertEqual(anchor.kind, "anchor"); XCTAssertNotEqual(anchor.anchor, oldAnchor)
            try phone.receiveInputFixtureForTesting(downstream.removeFirst())
            sink.refuse = false; executor.enabled = true; now = 10
            let fresh = expectation(description: "fresh post")
            host.onCausalInput = { context, _ in
                XCTAssertTrue(executor.submitCausal(context, steps: context.segments.map { self.admitted($0.action) }, semantic: nil,
                    routeAuthority: self.authority) { receipt in
                    XCTAssertFalse(receipt.failed); XCTAssertEqual(receipt.applied, 1); fresh.fulfill()
                })
            }
            XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 5, epoch: 7)]))
            try host.receiveInputFixtureForTesting(upstream.removeFirst())
            wait(for: [fresh], timeout: 2)
            XCTAssertTrue(host.connected); XCTAssertTrue(phone.connected)
            XCTAssertEqual(sink.events.last?.point.x, 105)
        }
    }

    func testReleaseLinearizesAfterInFlightPostingAndEmitsOneUp() {
        let sink = ExecutorSink(), executor = sink.executor()
        let started = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        sink.beforeMouse = { started.signal(); _ = unblock.wait(timeout: .now() + 2) }
        let done = expectation(description: "posted down")
        executor.submit(RemoteAction(action: "dragDown", interaction: NativeInteraction(hold: "owned", clickCount: 1)),
                        upgraded: true, expires: 11, routeAuthority: authority) { result in
            XCTAssertTrue(result.outcome.accepted); done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { executor.release(); released.signal() }
        XCTAssertEqual(released.wait(timeout: .now() + 0.02), .timedOut, "release cannot pass an in-flight posting fence")
        unblock.signal(); unblock.signal()
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.events.map(\.type), [.leftMouseDown, .leftMouseUp]); XCTAssertFalse(executor.held)
    }
    func testBoundedQueueRejectsAdditionalAcceptedWorkAndCleanupCancelsBacklog() {
        let queue = DispatchQueue(label: "full-input"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        queue.suspend()
        let done = expectation(description: "all queued cancelled"); done.expectedFulfillmentCount = HostInputExecutor.maximumQueued
        for _ in 0..<HostInputExecutor.maximumQueued {
            XCTAssertTrue(executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: 11, routeAuthority: authority) { result in
                XCTAssertFalse(result.outcome.accepted); done.fulfill()
            })
        }
        XCTAssertFalse(executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false, expires: 11, routeAuthority: authority) { _ in XCTFail("overflow must not enter queue") })
        executor.release(); queue.resume(); wait(for: [done], timeout: 2)
        XCTAssertTrue(sink.keys.isEmpty)
    }

    func testNegotiationHandoffRetainsAlreadyAdmittedLegacyPathBeforeAnchor() {
        let queue = DispatchQueue(label: "handoff-input"), sink = ExecutorSink(), executor = sink.executor(queue: queue)
        queue.suspend()
        let legacy = expectation(description: "legacy state")
        executor.submit(RemoteAction(action: "move", x: 10), upgraded: false, expires: 11, routeAuthority: authority) { result in
            XCTAssertTrue(result.outcome.accepted); legacy.fulfill()
        }
        executor.beginCausalContext(context())
        let upgraded = expectation(description: "upgraded state"), prefix = context([20])
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: nil, routeAuthority: authority) { result in
            XCTAssertFalse(result.failed); XCTAssertFalse(result.intervention); upgraded.fulfill()
        }
        queue.resume(); wait(for: [legacy, upgraded], timeout: 2)
        XCTAssertEqual(sink.pointer.x, 130, accuracy: 0.00001)
    }

    func testHealthyReenableEstablishesAnchorAfterDisabledEpochInvalidation() {
        let sink = ExecutorSink(), executor = sink.executor()
        executor.enabled = false; executor.beginCausalContext(context())
        executor.invalidateQueued(); executor.resetNativeSequence()
        sink.pointer.x = 70
        executor.enabled = true
        let prefix = context([5]), done = expectation(description: "new healthy epoch")
        executor.submitCausal(prefix, steps: prefix.segments.map { admitted($0.action) }, semantic: nil, routeAuthority: authority) { result in
            XCTAssertFalse(result.failed); XCTAssertFalse(result.intervention); done.fulfill()
        }
        wait(for: [done], timeout: 2); XCTAssertEqual(sink.pointer.x, 75, accuracy: 0.00001)
    }

    func testQueueWaitRechecksBothFreshnessDeadlineAndActiveHoldLease() {
        let queue = DispatchQueue(label: "lease-input"), sink = ExecutorSink()
        var now: TimeInterval = 10
        let executor = sink.executor(queue: queue, clock: { now })
        let down = expectation(description: "held")
        executor.submit(RemoteAction(action: "dragDown", interaction: NativeInteraction(hold: "lease", clickCount: 1)), upgraded: true,
                        expires: 100, routeAuthority: authority) { result in XCTAssertTrue(result.outcome.accepted); down.fulfill() }
        wait(for: [down], timeout: 2)
        queue.suspend()
        let late = expectation(description: "late"); late.expectedFulfillmentCount = 2
        executor.submit(RemoteAction(action: "move", x: 5, interaction: NativeInteraction(hold: "lease")), upgraded: true,
                        expires: 100, routeAuthority: authority) { result in XCTAssertFalse(result.outcome.accepted); late.fulfill() }
        executor.submit(RemoteAction(action: "key", key: "a"), upgraded: false,
                        expires: 11, routeAuthority: authority) { result in XCTAssertFalse(result.outcome.accepted); late.fulfill() }
        now = 12; queue.resume(); wait(for: [late], timeout: 2)
        XCTAssertEqual(sink.events.count, 1); XCTAssertTrue(sink.keys.isEmpty)
        XCTAssertTrue(executor.release()); XCTAssertEqual(sink.events.count, 2)
    }
    func testRevokeDuringCopyPreparationCannotPostOrReviveAuthority() {
        let sink = ExecutorSink(), executor = sink.executor(), preparation = DispatchGroup()
        preparation.enter()
        let done = expectation(description: "revoked prepared copy")
        executor.submit(RemoteAction(action: "key", key: "c"), upgraded: false, expires: 11,
                        preparation: preparation, routeAuthority: authority) { result in
            XCTAssertFalse(result.outcome.accepted); XCTAssertFalse(executor.accepts(result)); done.fulfill()
        }
        executor.enabled = false; preparation.leave()
        wait(for: [done], timeout: 2); XCTAssertTrue(sink.keys.isEmpty)
    }

}
