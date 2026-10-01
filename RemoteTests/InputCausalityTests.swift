import XCTest

final class InputCausalityTests: XCTestCase {
    private func envelope(_ actions: [RemoteAction], start: UInt64 = 1) -> InputCausalEnvelope {
        InputCausalEnvelope(kind: "barrier", nonce: String(repeating: "a", count: 32), anchor: String(repeating: "b", count: 32), epoch: 7,
                            applied: start + UInt64(actions.count) - 1,
                            segments: actions.enumerated().map { InputMotionSegment(ordinal: start + UInt64($0.offset), action: $0.element) })
    }
    func testLostMotionRecoveredExactlyOnceBySemanticPrefix() throws {
        let prefix = envelope([RemoteAction(action: "move", x: 500, epoch: 7), RemoteAction(action: "move", x: -80, epoch: 7)])
        var ledger = InputAppliedLedger()
        // Packet containing ordinal 1 was lost. Reliable semantic checkpoint contains the full path.
        XCTAssertEqual(try ledger.missing(from: prefix).map(\.action.x), [500, -80])
        for segment in try ledger.missing(from: prefix) { try ledger.recordPosted(segment.ordinal) }
        XCTAssertEqual(ledger.applied, 2)
        XCTAssertTrue(try ledger.missing(from: prefix).isEmpty, "late motion must not apply displacement twice")
        var old = prefix; old.segments = [prefix.segments[0]]; old.applied = 1
        XCTAssertTrue(try ledger.missing(from: old).isEmpty)
    }
    func testGapAndMixedGeometryNeverAuthorizeSemantic() throws {
        var prefix = envelope([RemoteAction(action: "move", x: 1, epoch: 7)], start: 2)
        XCTAssertThrowsError(try InputAppliedLedger().missing(from: prefix))
        prefix.segments[0].action.epoch = 8
        XCTAssertThrowsError(try prefix.validate())
        prefix.segments[0].action = RemoteAction(action: "key", key: "c", epoch: 7)
        XCTAssertThrowsError(try prefix.validate())
        prefix.version = 2
        XCTAssertThrowsError(try prefix.validate())
    }
    func testIndependentMotionReplayAcceptsReorderingButNotDuplicates() {
        var replay = InputMotionReplay()
        XCTAssertTrue(replay.accepts(8)); XCTAssertTrue(replay.accepts(6))
        XCTAssertFalse(replay.accepts(8)); XCTAssertFalse(replay.accepts(0))
        XCTAssertTrue(replay.accepts(200)); XCTAssertFalse(replay.accepts(6))
    }
    func testPrefixBoundAndAcknowledgementPreserveAcceptedPath() throws {
        var prefix = InputMotionPrefix()
        XCTAssertThrowsError(try prefix.append(RemoteAction(action: "text", text: "bad", epoch: 7)))
        XCTAssertEqual(prefix.next, 0)
        for n in 1...24 { try prefix.append(RemoteAction(action: "move", x: Double(n), epoch: 7)) }
        XCTAssertThrowsError(try prefix.append(RemoteAction(action: "move", x: 25, epoch: 7)))
        XCTAssertThrowsError(try prefix.acknowledge(25))
        try prefix.acknowledge(12)
        XCTAssertEqual(prefix.segments.map(\.ordinal), Array(13...24).map(UInt64.init))
        try prefix.append(RemoteAction(action: "move", x: 25, epoch: 7))
        XCTAssertEqual(prefix.segments.last?.ordinal, 25)
    }
    func testOldControlPacketAndNewOptionalEnvelopeRoundTrip() throws {
        let old = ControlPacket(session: "session", sequence: 1, action: RemoteAction(action: "key", key: "a", epoch: 7))
        XCTAssertNil(try JSONDecoder().decode(ControlPacket.self, from: JSONEncoder().encode(old)).input)
        let new = ControlPacket(session: "session", sequence: 2, action: RemoteAction(action: "click", epoch: 7), input: envelope([RemoteAction(action: "move", x: 2, epoch: 7)]))
        let decoded = try JSONDecoder().decode(ControlPacket.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded.input?.segments.first?.action.x, 2)
        XCTAssertTrue(SessionFeature.host.contains("input.causal.1"))
    }
    func testPostingDeadlineRemainsHostClockBoundAfterAdmission() {
        var freshness = NativeInputFreshness()
        let interaction = freshness.capability(epoch: 7, now: 10, doubleClickInterval: 0.5)
        let action = RemoteAction(action: "key", key: "a", epoch: 7, interaction: interaction)
        XCTAssertEqual(freshness.admit(action, epoch: 7, now: 10.2), .upgraded)
        XCTAssertEqual(freshness.postingDeadline(for: action, epoch: 7), 11)
        freshness.expireTokens()
        XCTAssertEqual(freshness.postingDeadline(for: action, epoch: 7), -.infinity)
    }
}

@MainActor
final class PointerChannelLoopbackTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition()); if !condition() { throw RemoteError.stale }
    }
    private func pair(phoneAccepts: Bool) async throws -> (PeerMedia, PeerMedia) {
        let host = PeerMedia(isHost: true, servers: []), phone = PeerMedia(isHost: false, servers: [])
        if phoneAccepts { phone.allowPointerChannel() }
        host.onSignal = { [weak phone] in phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        host.offer()
        try await wait { host.controlBufferedAmount != nil && phone.controlBufferedAmount != nil }
        host.openPointerChannel()
        return (host, phone)
    }
    func testNegotiatedUnorderedPointerAndIndependentOrderedControlDeliver() async throws {
        let (host, phone) = try await pair(phoneAccepts: true)
        defer { host.close(); phone.close() }
        var pointer: Data?, control: Data?
        host.onPointerMessage = { pointer = $0 }
        host.onControl = { control = $0 }
        let payload = Data("checkpoint".utf8)
        let deadline = Date().addingTimeInterval(10)
        var sent = false
        while !sent, Date() < deadline {
            sent = phone.sendPointer(payload)
            if !sent { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sent)
        try await wait { pointer != nil }; XCTAssertEqual(pointer, payload)
        XCTAssertTrue(phone.sendControl(Data("semantic".utf8)))
        try await wait { control != nil }; XCTAssertEqual(control, Data("semantic".utf8))
        XCTAssertNotNil(host.withInputPostingAuthority { true })
        host.close()
        XCTAssertNil(host.withInputPostingAuthority { true }, "closed lifetime cannot authorize posting")
    }
    func testUnnegotiatedOldPhoneRefusesPointerAndBaseControlRemainsOpen() async throws {
        let (host, phone) = try await pair(phoneAccepts: false)
        defer { host.close(); phone.close() }
        XCTAssertFalse(phone.sendPointer(Data([1])))
        var received: Data?
        host.onControl = { received = $0 }
        XCTAssertTrue(phone.sendControl(Data("old-control".utf8)))
        try await wait { received != nil }
        XCTAssertEqual(received, Data("old-control".utf8))
        XCTAssertNotNil(host.controlBufferedAmount)
        XCTAssertFalse(phone.sendPointer(Data(repeating: 0, count: 16385)))
    }
}

@MainActor
final class InputCoordinatorTests: XCTestCase {
    private func rig() -> (RemoteCoordinator, RemoteCoordinator) {
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), signaling: ScriptedSignaling())
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), signaling: ScriptedSignaling())
        host.startInputFixtureForTesting(session: "fixture"); phone.startInputFixtureForTesting(session: "fixture")
        host.setHostInputEpoch(7)
        return (host, phone)
    }
    func testExplicitAcknowledgementThenOverflowRecoveryKeepsSemanticBehindAllMotion() throws {
        let (host, phone) = rig()
        defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        XCTAssertFalse(phone.causalInputNegotiated)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        XCTAssertTrue(host.causalInputNegotiated)
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        XCTAssertTrue(phone.causalInputNegotiated)
        let moves = (1...24).map { RemoteAction(action: "move", x: Double($0), epoch: 7) }
        XCTAssertTrue(phone.sendInputMoves(moves)) // No native channel in fixture: reliable checkpoint fallback.
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 25, epoch: 7)]))
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "c", epoch: 7)))
        XCTAssertFalse(upstream.contains { $0.action.action == "key" }, "full prefix must commit before accepting the deferred semantic")
        var contexts: [InputCausalEnvelope] = []
        var semantics: [RemoteAction] = []
        host.onCausalInput = { context, semantic in contexts.append(context); if let semantic { semantics.append(semantic) } }
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        host.acknowledgeCausalInput(contexts[0], applied: 24)
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        let key = try XCTUnwrap(upstream.first { $0.action.action == "key" })
        XCTAssertEqual(key.input?.applied, 25)
        XCTAssertEqual(key.input?.segments.map(\.action.x), [25])
        try host.receiveInputFixtureForTesting(key)
        XCTAssertEqual(semantics.map(\.key), ["c"])
    }
    func testHighRateMotionWaitsOneReliableCheckpointAndKeepsSemanticOrderAcrossAckStalls() throws {
        for hz in [120, 240] {
            for delay in [0.3, 1.0] {
                let (host, phone) = rig()
                defer { host.stop(); phone.stop() }
                var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
                host.inputPacketSenderForTesting = { downstream.append($0); return true }
                phone.inputPacketSenderForTesting = { upstream.append($0); return true }
                phone.requestCausalInput(epoch: 7)
                try host.receiveInputFixtureForTesting(upstream.removeFirst())
                try phone.receiveInputFixtureForTesting(downstream.removeFirst())
                var ledger = InputAppliedLedger(), displacement = 0.0, keys: [String] = []
                host.onCausalInput = { context, semantic in
                    for segment in try! ledger.missing(from: context) {
                        displacement += segment.action.x; try! ledger.recordPosted(segment.ordinal)
                    }
                    if let semantic { keys.append(semantic.key) }
                    host.acknowledgeCausalInput(context, applied: ledger.applied)
                }
                let count = Int(Double(hz) * delay)
                for tick in 0..<count {
                    XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 1, epoch: 7)]))
                    if tick == count / 2 { XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 7))) }
                }
                XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "b", epoch: 7)))
                XCTAssertEqual(upstream.filter { $0.action.action == "heartbeat" }.count, 1,
                               "Do not flood reliable control while ACK is delayed by \(delay)s at \(hz)Hz")
                var rounds = 0
                while !upstream.isEmpty || !downstream.isEmpty {
                    rounds += 1; XCTAssertLessThan(rounds, 100)
                    if rounds >= 100 { break }
                    while !upstream.isEmpty { try host.receiveInputFixtureForTesting(upstream.removeFirst()) }
                    while !downstream.isEmpty { try phone.receiveInputFixtureForTesting(downstream.removeFirst()) }
                }
                XCTAssertEqual(displacement, Double(count))
                XCTAssertEqual(keys, ["a", "b"])
                XCTAssertTrue(phone.connected); XCTAssertTrue(phone.isRunning)
                XCTAssertTrue(host.connected); XCTAssertTrue(host.isRunning)
            }
        }
    }

    func testHostDroppedReliableCheckpointIsResentAndDeferredSemanticStillPosts() async throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        var ledger = InputAppliedLedger(), displacement = 0.0, keys: [String] = [], dropNext = true
        host.onCausalInput = { context, semantic in
            // Executor generation moved mid-batch: the host drops it with no ACK and no anchor.
            if dropNext { dropNext = false; return }
            for segment in try! ledger.missing(from: context) {
                displacement += segment.action.x; try! ledger.recordPosted(segment.ordinal)
            }
            if let semantic { keys.append(semantic.key) }
            host.acknowledgeCausalInput(context, applied: ledger.applied)
        }
        // Fill the 24-segment prefix so later work is deferred behind the one reliable checkpoint.
        for _ in 0..<25 { XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 1, epoch: 7)])) }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 7)))
        XCTAssertEqual(upstream.count, 1)
        XCTAssertFalse(upstream.contains { $0.action.action == "key" }, "The key waits behind the full prefix")
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        XCTAssertTrue(downstream.isEmpty, "Fixture host dropped the checkpoint silently")
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 1, epoch: 7)]))
        XCTAssertTrue(upstream.isEmpty, "Still one checkpoint in flight before the retransmit interval")

        let deadline = Date().addingTimeInterval(3)
        while upstream.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let resent = try XCTUnwrap(upstream.first, "A dropped reliable checkpoint must be resent, not wait for overflow")
        XCTAssertEqual(resent.action.action, "heartbeat"); XCTAssertEqual(resent.input?.kind, "barrier")
        XCTAssertEqual(resent.input?.segments.map(\.ordinal), Array(1...24))
        var rounds = 0
        while !upstream.isEmpty || !downstream.isEmpty {
            rounds += 1; XCTAssertLessThan(rounds, 100); if rounds >= 100 { break }
            while !upstream.isEmpty { try host.receiveInputFixtureForTesting(upstream.removeFirst()) }
            while !downstream.isEmpty { try phone.receiveInputFixtureForTesting(downstream.removeFirst()) }
        }
        XCTAssertEqual(displacement, 26); XCTAssertEqual(keys, ["a"])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(upstream.isEmpty, "An acknowledged checkpoint is never resent")
        XCTAssertTrue(phone.connected); XCTAssertTrue(phone.isRunning)
        XCTAssertTrue(host.connected); XCTAssertTrue(host.isRunning)
    }

    func testOneSecond240HzPencilPressureStallRetainsEverySampleAndEndOrder() throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        let contact = String(repeating: "a", count: 32)
        var ledger = InputAppliedLedger(), observed: [Double] = [], ended = false
        host.onCausalInput = { context, semantic in
            for segment in try! ledger.missing(from: context) {
                observed.append(segment.action.pencil!.pressure); try! ledger.recordPosted(segment.ordinal)
            }
            if semantic?.action == "dragUp" { ended = true; XCTAssertEqual(observed.count, 240) }
            host.acknowledgeCausalInput(context, applied: ledger.applied)
        }
        for index in 1...240 {
            let frame = PencilFrame(stream: contact, phase: .moved, pressure: Double(index) / 240, tiltX: 0, tiltY: 0)
            XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "moveTo", x: Double(index), epoch: 7,
                interaction: NativeInteraction(hold: contact, clickCount: 1), pencil: frame)]))
        }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "dragUp", epoch: 7,
            interaction: NativeInteraction(hold: contact, clickCount: 1),
            pencil: PencilFrame(stream: contact, phase: .ended, pressure: 0, tiltX: 0, tiltY: 0))))
        XCTAssertEqual(upstream.count, 1, "One reliable motion checkpoint while ACK is withheld for1s")
        var rounds = 0
        while !upstream.isEmpty || !downstream.isEmpty {
            rounds += 1; XCTAssertLessThan(rounds, 100); if rounds >= 100 { break }
            while !upstream.isEmpty { try host.receiveInputFixtureForTesting(upstream.removeFirst()) }
            while !downstream.isEmpty { try phone.receiveInputFixtureForTesting(downstream.removeFirst()) }
        }
        XCTAssertEqual(observed, (1...240).map { Double($0) / 240 }); XCTAssertTrue(ended)
        XCTAssertTrue(phone.connected); XCTAssertTrue(host.connected)
    }

    func testGeometryAdvancingDuringInitialOfferClearsRetiredInputAndKeepsBothPeersLive() throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 99, epoch: 7)]))
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "retired draft", key: "draft", epoch: 7)))
        host.setHostInputEpoch(8)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        let response = try XCTUnwrap(downstream.first)
        XCTAssertEqual(response.input?.epoch, 8)
        var epochs: [UInt64] = []; phone.onCausalContext = { epochs.append($0.epoch) }
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        XCTAssertEqual(epochs, [8]); XCTAssertTrue(upstream.isEmpty)
        XCTAssertFalse(phone.sendInputMoves([RemoteAction(action: "move", x: 1, epoch: 7)]))
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 2, epoch: 8)]))
        XCTAssertEqual(upstream.last?.input?.segments.map(\.action.x), [2])
        XCTAssertTrue(host.connected); XCTAssertTrue(host.isRunning); XCTAssertTrue(phone.connected); XCTAssertTrue(phone.isRunning)
    }

    func testSupersededInitialAcceptCannotEndTheNewerNegotiation() throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 99, epoch: 7)]))
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "retired draft", key: "draft", epoch: 7)))
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        host.setHostInputEpoch(8)
        phone.requestCausalInput(epoch: 8)
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 8)))
        XCTAssertFalse(phone.sendControl(RemoteAction(action: "release", epoch: 7)))
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        let oldAccept = downstream.removeFirst()
        XCTAssertNoThrow(try phone.receiveInputFixtureForTesting(oldAccept))
        XCTAssertNoThrow(try phone.receiveInputFixtureForTesting(downstream.removeFirst()), "Old-nonce anchor before new accept is harmless")
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        XCTAssertTrue(phone.causalInputNegotiated); XCTAssertTrue(phone.connected)
        XCTAssertEqual(upstream.count, 1, "Only new-scope key survives; retired text/motion never replay")
        XCTAssertEqual(upstream.first?.action.key, "a"); XCTAssertEqual(upstream.first?.action.epoch, 8)
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 2, epoch: 8)]))
        XCTAssertEqual(upstream.last?.input?.segments.map(\.action.x), [2])
    }

    func testUnsentCoalescingPreservesReversalAndAuthorityBoundaries() {
        XCTAssertEqual(PointerMoveCoalescer.coalescedUnsentMove(RemoteAction(action: "move", x: 2, epoch: 7),
                       RemoteAction(action: "move", x: 3, epoch: 7))?.x, 5)
        XCTAssertNil(PointerMoveCoalescer.coalescedUnsentMove(RemoteAction(action: "move", x: 2, epoch: 7),
                     RemoteAction(action: "move", x: -3, epoch: 7)), "Keep the clamped path through reversals")
        XCTAssertNil(PointerMoveCoalescer.coalescedUnsentMove(RemoteAction(action: "move", x: 2, epoch: 7, interaction: NativeInteraction(token: "old")),
                     RemoteAction(action: "move", x: 3, epoch: 7, interaction: NativeInteraction(token: "new"))))
    }

    func testBoundedOverflowRequestsExactContextRecoveryWithoutStoppingSharingOrReplayingText() throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        var cleanups = 0, posted: [String] = []
        host.onCausalRecovery = { cleanups += 1 }
        host.onCausalInput = { _, action in if let action { posted.append(action.text) } }
        var refused = false
        // Reversals may not merge; exceeding the bounded tail must rebase, not fail.
        for tick in 0..<600 {
            if !phone.sendInputMoves([RemoteAction(action: "move", x: tick % 2 == 0 ? 1 : -1, epoch: 7)]) { refused = true; break }
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(upstream.filter { $0.input?.kind == "rebase" }.count, 1)
        XCTAssertFalse(phone.sendControl(RemoteAction(action: "text", text: "must not replay", key: "draft", epoch: 7)))
        XCTAssertTrue(phone.connected); XCTAssertTrue(phone.isRunning)
        XCTAssertTrue(host.connected); XCTAssertTrue(host.isRunning)
        while !upstream.isEmpty { try host.receiveInputFixtureForTesting(upstream.removeFirst()) }
        XCTAssertEqual(cleanups, 1)
        while !downstream.isEmpty { try phone.receiveInputFixtureForTesting(downstream.removeFirst()) }
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 7)))
        let fresh = try XCTUnwrap(upstream.last)
        XCTAssertTrue(fresh.input?.segments.isEmpty == true)
        XCTAssertTrue(phone.connected); XCTAssertTrue(host.connected)
        let foreign = try XCTUnwrap(fresh.input)
        var stale = foreign; stale.anchor = InputCausalEnvelope.identity()
        XCTAssertFalse(host.recoverCausalInput(stale)); XCTAssertEqual(cleanups, 1)
    }

    func testInvalidLegacyInputEndsOnlyPeerAndLeavesHostRegistrationRunning() {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        host.endPhoneInputSession("fixture rejection")
        XCTAssertTrue(host.isRunning); XCTAssertTrue(host.hostRegistered)
        XCTAssertFalse(host.connected)
    }

    func testUnnegotiatedOldPeerKeepsPlainPacketsAndLateForeignAnchorCannotApply() throws {
        let (host, phone) = rig()
        defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 3, epoch: 7)]))
        XCTAssertNil(upstream.last?.input)
        upstream.removeAll()
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "exact", key: "draft", epoch: 7)))
        let stale = upstream.removeFirst()
        host.rebaseCausalInput()
        var applied = 0, refused = 0
        host.onCausalInput = { _, _ in applied += 1 }
        host.onCausalRejected = { if $0.action == "text" { refused += 1 } }
        try host.receiveInputFixtureForTesting(stale)
        XCTAssertEqual(applied, 0); XCTAssertEqual(refused, 1)
        var foreign = stale; foreign.session = "other"
        XCTAssertThrowsError(try host.receiveInputFixtureForTesting(foreign))
    }
    func testReorderedMotionCannotAdvanceReliableControlSequenceAndDuplicateOfferDoesNotResetContext() throws {
        let (host, phone) = rig()
        defer { host.stop(); phone.stop() }
        var offer: ControlPacket?, accept: ControlPacket?
        phone.inputPacketSenderForTesting = { offer = $0; return true }
        host.inputPacketSenderForTesting = { accept = $0; return true }
        phone.requestCausalInput(epoch: 7)
        try host.receiveInputFixtureForTesting(try XCTUnwrap(offer))
        let original = try XCTUnwrap(accept)
        try phone.receiveInputFixtureForTesting(original)
        var deliveries = 0
        host.onCausalInput = { _, _ in deliveries += 1 }
        var motion = original; motion.sequence = 8; motion.input?.kind = "motion"
        try host.receiveInputFixtureForTesting(motion, motion: true)
        motion.sequence = 6; try host.receiveInputFixtureForTesting(motion, motion: true)
        motion.sequence = 8; try host.receiveInputFixtureForTesting(motion, motion: true)
        XCTAssertEqual(deliveries, 2)
        var contextChanges = 0; host.onCausalContext = { _ in contextChanges += 1 }
        var duplicateOffer = try XCTUnwrap(offer); duplicateOffer.sequence = 2
        try host.receiveInputFixtureForTesting(duplicateOffer)
        XCTAssertEqual(contextChanges, 0)
        var reliable = original; reliable.sequence = 3; reliable.input?.kind = "barrier"
        try host.receiveInputFixtureForTesting(reliable)
        XCTAssertEqual(deliveries, 3)
    }
    func testOfferPendingBuffersInputAndNegotiatedHostRejectsMixedPlainSemantics() throws {
        let (host, phone) = rig(); defer { host.stop(); phone.stop() }
        var upstream: [ControlPacket] = [], downstream: [ControlPacket] = []
        phone.inputPacketSenderForTesting = { upstream.append($0); return true }
        host.inputPacketSenderForTesting = { downstream.append($0); return true }
        phone.requestCausalInput(epoch: 7)
        XCTAssertTrue(phone.sendInputMoves([RemoteAction(action: "move", x: 9, epoch: 7)]))
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 7)))
        XCTAssertEqual(upstream.count, 1, "no plain user input may escape while its offer awaits ACK")
        try host.receiveInputFixtureForTesting(upstream.removeFirst())
        try phone.receiveInputFixtureForTesting(downstream.removeFirst())
        let semantic = try XCTUnwrap(upstream.first { $0.action.action == "key" })
        XCTAssertEqual(semantic.input?.segments.map(\.action.x), [9])
        var mixed = semantic; mixed.input = nil
        XCTAssertThrowsError(try host.receiveInputFixtureForTesting(mixed))
    }

}

final class InputFeatureCompatibilityTests: XCTestCase {
    private struct HistoricalCapture: Decodable {
        let action: String, features: [String]
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            action = try values.decode(String.self, forKey: .action)
            features = try values.decode([String].self, forKey: .features)
            guard action == "capture", features.count <= 16,
                  features.allSatisfy({ (1...32).contains($0.utf8.count) }) else { throw RemoteError.invalidMessage }
        }
        enum CodingKeys: CodingKey { case action, features }
    }
    private func capture(_ peer: Set<String>, mode: SessionMode = .picture, bigText: Bool = true, future: [String] = []) -> Data {
        let features = HostFeatureList.features(base: SessionFeature.host + [SessionFeature.couch] + future,
            allowBigText: bigText, accessibility: true, peerFeatures: peer, requestedMode: mode)
        return try! JSONEncoder().encode(RemoteAction(action: "capture", epoch: 7, features: features))
    }
    func testHistoricalPictureCaptureDecodesFullMessageAndKeepsItsOriginalSixteenFeatures() throws {
        for bigText in [false, true] {
            let decoded = try JSONDecoder().decode(HistoricalCapture.self, from: capture([], bigText: bigText, future: ["scope.1", "future.1"]))
            XCTAssertEqual(decoded.features, SessionFeature.legacyHost)
            let current = try JSONDecoder().decode(RemoteAction.self, from: capture([], bigText: bigText))
            XCTAssertNoThrow(try current.validate())
            XCTAssertFalse(decoded.features.contains(SessionFeature.causalInput)); XCTAssertFalse(decoded.features.contains(SessionFeature.displayScale))
        }
    }
    func testHistoricalCouchRetainsModeWithinItsSixteenFeatureBound() throws {
        let decoded = try JSONDecoder().decode(HistoricalCapture.self, from: capture([], mode: .couch))
        XCTAssertEqual(decoded.features.count, 16); XCTAssertEqual(decoded.features.first, SessionFeature.couch)
        XCTAssertTrue(decoded.features.contains(SessionFeature.clipboardText))
        XCTAssertTrue(decoded.features.contains(SessionFeature.focusGeometry))
        XCTAssertFalse(decoded.features.contains(SessionFeature.causalInput))
    }
    func testCurrentHandshakeProvesCapacityAndInputSeparatelyAndKeepsBigTextAndFutureScope() throws {
        let body = try JSONEncoder().encode(MacShareBlocker.Handshake.phone)
        let peer = MacShareBlocker.Handshake.features(in: body)
        XCTAssertLessThanOrEqual(peer.count, 8)
        XCTAssertTrue(peer.contains(SessionFeature.extendedFeatureList)); XCTAssertTrue(peer.contains(SessionFeature.causalInput))
        for bigText in [false, true] {
            let data = capture(peer, bigText: bigText, future: ["scope.1"])
            let decoded = try JSONDecoder().decode(RemoteAction.self, from: data)
            XCTAssertNoThrow(try decoded.validate())
            XCTAssertTrue(decoded.features?.contains(SessionFeature.causalInput) == true)
            XCTAssertTrue(decoded.features?.contains(SessionFeature.couch) == true)
            XCTAssertTrue(decoded.features?.contains("scope.1") == true)
            XCTAssertEqual(decoded.features?.contains(SessionFeature.displayScale), bigText)
            XCTAssertThrowsError(try JSONDecoder().decode(HistoricalCapture.self, from: data))
        }
        let capacityOnly = try JSONDecoder().decode(RemoteAction.self, from: capture([SessionFeature.extendedFeatureList]))
        XCTAssertFalse(capacityOnly.features?.contains(SessionFeature.causalInput) == true)
        let inputOnly = try JSONDecoder().decode(HistoricalCapture.self, from: capture([SessionFeature.causalInput]))
        XCTAssertFalse(inputOnly.features.contains(SessionFeature.causalInput))
    }
    func testAppendedFutureFeaturesRemainWithinProvenCaptureCapacity() throws {
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: capture([SessionFeature.extendedFeatureList, SessionFeature.causalInput], future: (1...40).map { "future.\($0)" }))
        XCTAssertEqual(decoded.features?.count, 32); XCTAssertNoThrow(try decoded.validate())
        XCTAssertTrue(decoded.features?.contains(SessionFeature.couch) == true)
        XCTAssertTrue(decoded.features?.contains(SessionFeature.displayScale) == true)
    }
}
