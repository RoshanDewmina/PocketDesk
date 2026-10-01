import XCTest
import CoreVideo
import WebRTC

final class FrameTimingTests: XCTestCase {
    private func host(_ rtp: UInt32, _ bytes: Int, display: Double = 1_000, encoded: Double = 1_012) -> HostFrameRecord {
        HostFrameRecord(localRtp: rtp, bytes: bytes, displayMs: display, pushMs: display + 3, encodedMs: encoded)
    }

    private func phone(_ rtp: UInt32, _ bytes: Int, decoded: Double? = 1_040) -> PhoneFrameRecord {
        PhoneFrameRecord(wireRtp: rtp, bytes: bytes, arrivalMs: 1_030, decodedMs: decoded)
    }

    private let sizes = [900, 1_200, 450, 3_100, 870, 1_500, 2_222, 640]

    func testHugeFiniteStageDifferencesClampBeforeIntegerConversion() throws {
        let record = HostFrameRecord(localRtp: 1, bytes: 20, displayMs: 1,
                                     pushMs: 1, encodedMs: 1e300)
        let records = try XCTUnwrap(FrameTimingRecords([record]))
        XCTAssertEqual(records.display, [FrameTimingRecords.stageLimit])
        XCTAssertEqual(records.push, [FrameTimingRecords.stageLimit])
        XCTAssertThrowsError(try records.validate(), "unsupported clock ranges are rejected")
    }

    func testReceiverRejectsMismatchedParallelArraysWithoutAccessingThem() {
        let log = PhoneFrameTimingLog()
        let receiver = FrameTimingReceiver(log: log)
        var records = FrameTimingRecords([host(1, 20)])!
        records.bytes = []
        receiver.receive(records, clock: nil)
        XCTAssertFalse(log.isActive)
        XCTAssertNil(receiver.drain())
    }

    // MARK: Join

    func testJoinLocksOnTheOffsetWhoseSizesMatch() {
        let offset: UInt32 = 1_234_567
        let hosts = sizes.enumerated().map { host(UInt32(10_000 + $0.offset * 1_500), $0.element) }
        let phones = [phone(5, 900), phone(77, 1_200)] + hosts.map { phone($0.localRtp &+ offset, $0.bytes) }
        var join = FrameTimingJoin()
        let pairs = join.match(host: hosts, phone: phones)
        XCTAssertEqual(join.offset, offset)
        XCTAssertEqual(pairs.map(\.host), hosts)
        XCTAssertEqual(pairs.map(\.phone.wireRtp), hosts.map { $0.localRtp &+ offset })
    }

    func testJoinNeedsFourMatchingSizesToLock() {
        let hosts = sizes.prefix(3).enumerated().map { host(UInt32($0.offset * 1_500), $0.element) }
        var join = FrameTimingJoin()
        XCTAssertTrue(join.match(host: hosts, phone: hosts.map { phone($0.localRtp &+ 99, $0.bytes) }).isEmpty)
        XCTAssertNil(join.offset)
    }

    func testJoinRejectsARunnerUpWithMoreThanHalfTheVotes() {
        let hosts = sizes.prefix(7).enumerated().map { host(UInt32(50_000 + $0.offset * 1_500), $0.element) }
        let a: UInt32 = 700, b: UInt32 = 90_000
        var phones = hosts.prefix(4).map { phone($0.localRtp &+ a, $0.bytes) }
        phones += hosts.suffix(3).map { phone($0.localRtp &+ b, $0.bytes) }
        var join = FrameTimingJoin()
        XCTAssertTrue(join.match(host: hosts, phone: phones).isEmpty, "4 votes against 3 is too close")
        XCTAssertNil(join.offset)

        let more = sizes.suffix(1).map { host(UInt32(80_000), $0) } + [host(81_500, 4_321)]
        let widened = hosts + more
        phones += more.map { phone($0.localRtp &+ a, $0.bytes) }
        XCTAssertEqual(join.match(host: widened, phone: phones).count, 6)
        XCTAssertEqual(join.offset, a, "6 votes against 3 locks")
    }

    func testJoinUnlocksAndRelocksWhenTheOffsetChanges() {
        let first = sizes.enumerated().map { host(UInt32(1_000 + $0.offset * 1_500), $0.element) }
        var join = FrameTimingJoin()
        _ = join.match(host: first, phone: first.map { phone($0.localRtp &+ 10, $0.bytes) })
        XCTAssertEqual(join.offset, 10)

        let second = sizes.reversed().enumerated().map { host(UInt32(40_000 + $0.offset * 1_500), $0.element) }
        let pairs = join.match(host: second, phone: second.map { phone($0.localRtp &+ 5_000_000, $0.bytes) })
        XCTAssertEqual(join.offset, 5_000_000, "a new session or stream start moves the offset")
        XCTAssertEqual(pairs.count, second.count)

        let unrelated = second.enumerated().map { phone(UInt32($0.offset * 7_919 + 3), $0.element.bytes) }
        XCTAssertTrue(join.match(host: second, phone: unrelated).isEmpty)
        XCTAssertNil(join.offset, "matching sizes with no consistent offset unlock")
    }

    func testJoinKeepsItsLockWhenABatchBarelyOverlapsThePhoneRing() {
        let hosts = sizes.enumerated().map { host(UInt32(1_000 + $0.offset * 1_500), $0.element) }
        var join = FrameTimingJoin()
        _ = join.match(host: hosts, phone: hosts.map { phone($0.localRtp &+ 10, $0.bytes) })
        XCTAssertTrue(join.match(host: hosts, phone: [phone(1, 900)]).isEmpty)
        XCTAssertEqual(join.offset, 10)
    }

    func testJoinHandlesRTPWraparound() {
        let hosts = sizes.enumerated().map { host(UInt32.max - 6_000 &+ UInt32($0.offset * 1_500), $0.element) }
        let offset: UInt32 = 100_000
        var join = FrameTimingJoin()
        let pairs = join.match(host: hosts, phone: hosts.map { phone($0.localRtp &+ offset, $0.bytes) })
        XCTAssertEqual(join.offset, offset)
        XCTAssertEqual(pairs.count, hosts.count)
        XCTAssertLessThan(pairs.last!.host.localRtp, pairs.first!.host.localRtp, "local timestamps wrapped too")
        XCTAssertLessThan(pairs.first!.phone.wireRtp, offset, "wire timestamps wrapped past zero")
    }

    // MARK: Host log and records

    func testHostLogJoinsPushToEncodedOutputByBufferAndCaptureKey() throws {
        let log = HostFrameTimingLog()
        let fresh = NSObject(), resend = NSObject(), dropped = NSObject()
        log.pushed(ObjectIdentifier(fresh), displayMs: 1_000, pushMs: 1_004)
        log.pushed(ObjectIdentifier(dropped), displayMs: 1_010, pushMs: 1_012)
        log.pushed(ObjectIdentifier(resend), displayMs: 0, pushMs: 1_020)
        log.submitted(ObjectIdentifier(fresh), key: 55)
        log.submitted(ObjectIdentifier(resend), key: 56)
        log.submitted(nil, key: 57)
        log.encoded(key: 56, localRtp: 9, bytes: 40, atMs: 1_030)
        log.encoded(key: 55, localRtp: 8, bytes: 900, atMs: 1_032)
        log.encoded(key: 99, localRtp: 7, bytes: 10, atMs: 1_033)
        let drain = log.drain()
        let records = try XCTUnwrap(drain.records).records
        XCTAssertEqual(records.map(\.localRtp), [9, 8])
        XCTAssertEqual(records.map(\.bytes), [40, 900])
        XCTAssertTrue(records[0].isResend)
        XCTAssertEqual(records[1].displayMs, 1_000, accuracy: 0.05)
        XCTAssertEqual(records[1].pushMs, 1_004, accuracy: 0.05)
        XCTAssertEqual(records[1].encodedMs, 1_032, accuracy: 0.05)
        XCTAssertNil(log.drain().records, "each record is sent once")
    }

    func testHostPercentilesExcludeResends() {
        let log = HostFrameTimingLog()
        for (index, latency) in [10.0, 20, 30, 400, 400].enumerated() {
            let buffer = NSObject()
            let resend = index >= 3
            log.pushed(ObjectIdentifier(buffer), displayMs: resend ? 0 : 1_000, pushMs: 1_001)
            log.submitted(ObjectIdentifier(buffer), key: Int64(index))
            log.encoded(key: Int64(index), localRtp: UInt32(index), bytes: 100, atMs: 1_000 + latency)
        }
        let drain = log.drain()
        XCTAssertEqual(drain.p50Ms, 20)
        XCTAssertEqual(drain.maxMs, 30, "an idle re-send has no display time, so no latency")
        XCTAssertEqual(drain.records?.rtp.count, 5, "re-sends still travel for the join")
    }

    func testRecordsKeepTheNewest64AndStayWellUnderTheControlLimitAt120FPS() throws {
        let log = HostFrameTimingLog()
        let start = 86_400_000.0 * 30
        for index in 0..<120 {
            let buffer = NSObject()
            let display = start + Double(index) * 8.333
            log.pushed(ObjectIdentifier(buffer), displayMs: index % 17 == 0 ? 0 : display, pushMs: display + 4.44)
            log.submitted(ObjectIdentifier(buffer), key: Int64(index))
            log.encoded(key: Int64(index), localRtp: UInt32.max - 50_000 &+ UInt32(index * 750),
                        bytes: index == 119 ? 4_999_999 : 123_456 + index, atMs: display + 23.456)
        }
        let drain = log.drain()
        let records = try XCTUnwrap(drain.records)
        XCTAssertEqual(records.rtp.count, FrameTimingRecords.maximumCount)
        XCTAssertEqual(records.rtp.last, UInt32.max - 50_000 &+ UInt32(119 * 750))
        XCTAssertNoThrow(try records.validate())

        var summary = HostStreamSummary(captureFPS: 119.9, captureLatencyMs: 7.5, captureGapP90Ms: 18, pushSkipped: 0,
                                        droppedBeforeEncode: 1, encodedFPS: 119.9, encodeMs: 9.4, pacerDelayMs: 1.2,
                                        sentFPS: 119.9, sentKbps: 24_200, targetKbps: 25_000, maxKbps: 25_000,
                                        qpAverage: 30, sentWidth: 2560, sentHeight: 1664,
                                        encoder: String(repeating: "E", count: 48), hardwareEncoder: true,
                                        qualityLimitation: String(repeating: "q", count: 24))
        summary.applyFrameTiming(drain)
        let action = RemoteAction(action: "capture", x: 1, epoch: 99, hostStream: summary)
        XCTAssertNoThrow(try action.validate())
        let packet = try JSONEncoder().encode(ControlPacket(session: String(repeating: "s", count: 64),
                                                           sequence: .max, action: action))
        XCTAssertLessThan(packet.count, 6_144, "\(packet.count) B; the control limit is 16 KB")
    }

    func testRecordsRoundTripWithinATenthOfAMillisecond() throws {
        let original = [host(4_000_000_000, 2_000, display: 5_000.04, encoded: 5_021.26),
                        HostFrameRecord(localRtp: 12, bytes: 31, displayMs: 0, pushMs: 5_030, encodedMs: 5_031.5)]
        let decoded = try JSONDecoder().decode(FrameTimingRecords.self,
                                               from: JSONEncoder().encode(XCTUnwrap(FrameTimingRecords(original))))
        for (a, b) in zip(original, decoded.records) {
            XCTAssertEqual(a.localRtp, b.localRtp)
            XCTAssertEqual(a.bytes, b.bytes)
            XCTAssertEqual(a.isResend, b.isResend)
            XCTAssertEqual(a.encodedMs, b.encodedMs, accuracy: 0.051)
            XCTAssertEqual(a.pushMs, b.pushMs, accuracy: 0.11)
            if !a.isResend { XCTAssertEqual(a.displayMs, b.displayMs, accuracy: 0.11) }
        }
        XCTAssertNil(FrameTimingRecords([]))
    }

    func testRecordValidationBoundsEveryArray() throws {
        let valid = try XCTUnwrap(FrameTimingRecords((0..<4).map { host(UInt32($0), 100 + $0) }))
        XCTAssertNoThrow(try valid.validate())
        var mismatched = valid; mismatched.push.removeLast()
        var tooMany = valid
        tooMany.rtp = Array(repeating: 1, count: 65); tooMany.bytes = Array(repeating: 1, count: 65)
        tooMany.encoded = Array(repeating: 1, count: 65); tooMany.display = Array(repeating: 1, count: 65)
        tooMany.push = Array(repeating: 1, count: 65)
        var negative = valid; negative.bytes[0] = -1
        var farDisplay = valid; farDisplay.display[1] = -2
        var badBase = valid; badBase.baseMs = .nan
        for bad in [mismatched, tooMany, negative, farDisplay, badBase] {
            XCTAssertThrowsError(try bad.validate())
            var summary = HostStreamSummary(); summary.frameRecords = bad
            XCTAssertThrowsError(try RemoteAction(action: "capture", hostStream: summary).validate())
        }
        var summary = HostStreamSummary(); summary.frameHostP95Ms = -1
        XCTAssertThrowsError(try summary.validate())
    }

    // MARK: Summary protocol

    func testSummaryRoundTripsAndOlderPeersIgnoreTheNewFields() throws {
        var summary = HostStreamSummary(captureFPS: 60, encoder: "VideoToolbox")
        summary.frameHostP50Ms = 18.5; summary.frameHostP95Ms = 30.1; summary.frameHostMaxMs = 44
        summary.frameRecords = FrameTimingRecords([host(7, 900), host(8, 40, display: 0)])
        let json = try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, hostStream: summary))
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: json)
        XCTAssertEqual(decoded.hostStream, summary)
        XCTAssertNoThrow(try decoded.validate())

        struct OlderSummary: Decodable { var captureFPS: Double?; var encoder: String? }
        struct OlderAction: Decodable { var action: String; var hostStream: OlderSummary? }
        let older = try JSONDecoder().decode(OlderAction.self, from: json)
        XCTAssertEqual(older.hostStream?.captureFPS, 60)

        let oldJSON = Data(#"{"captureFPS":60,"encoder":"VideoToolbox"}"#.utf8)
        let fromOldHost = try JSONDecoder().decode(HostStreamSummary.self, from: oldJSON)
        XCTAssertNil(fromOldHost.frameRecords)
        XCTAssertNil(fromOldHost.frameHostP50Ms)

        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.applyPhoneFrameTiming(FrameTimingReceiver.Drain(p50Ms: 41.04, p95Ms: 60, maxMs: 70, count: 50, locked: true))
        let reportJSON = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(StreamStatsReport.self, from: reportJSON), report)
        XCTAssertEqual(report.frameToPhoneP50Ms, 41)
        struct OlderReport: Decodable { var role: String }
        XCTAssertEqual(try JSONDecoder().decode(OlderReport.self, from: reportJSON).role, "phone")
    }

    func testOverlayShowsOneFrameTimingLine() {
        var phoneReport = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        XCTAssertNil(phoneReport.frameTimingLine, "nothing from an older Mac")
        var summary = HostStreamSummary(); summary.frameHostP50Ms = 18.5; summary.frameHostP95Ms = 31
        phoneReport.host = summary
        phoneReport.applyPhoneFrameTiming(FrameTimingReceiver.Drain(p50Ms: 41, p95Ms: 60, maxMs: 70, count: 50, locked: true))
        phoneReport.clockUncertaintyMs = 1.5
        let lines = phoneReport.summaryLines.filter { $0.hasPrefix("heuristic RTP/size join · frame host") }
        XCTAssertEqual(lines, ["heuristic RTP/size join · frame host p50 18.5ms p95 31.0ms · to phone p50 41.0ms p95 60.0ms (n 50, ±1.5ms)"])

        phoneReport.frameJoinLocked = false
        XCTAssertEqual(phoneReport.frameTimingLine, "heuristic RTP/size join · frame host p50 18.5ms p95 31.0ms · to phone – (join pending)")

        var hostReport = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        hostReport.applyHostFrameTiming(HostFrameTimingLog.Drain(p50Ms: 12, p95Ms: 20, maxMs: 25.04))
        XCTAssertEqual(hostReport.summaryLines.filter { $0.hasPrefix("frame host") },
                       ["frame host p50 12.0ms p95 20.0ms max 25.0ms"])
    }

    // MARK: Phone

    func testPhoneLogMatchesDecodesByWireTimestampAcrossTheSignBit() {
        let log = PhoneFrameTimingLog()
        log.received(wireRtp: UInt32.max - 1, bytes: 10, atMs: 5)
        log.received(wireRtp: 3, bytes: 11, atMs: 6)
        log.decoded(rtp: Int32(bitPattern: UInt32.max - 1), atMs: 9)
        log.decoded(rtp: 12345, atMs: 10)
        XCTAssertEqual(log.snapshot().map(\.decodedMs), [9, nil])
        XCTAssertEqual(log.counts.received, 2)
        XCTAssertEqual(log.counts.decoded, 2)
        for index in 0..<(PhoneFrameTimingLog.capacity + 5) {
            log.received(wireRtp: UInt32(100 + index), bytes: 1, atMs: 1)
        }
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.count, PhoneFrameTimingLog.capacity)
        XCTAssertEqual(snapshot.last?.wireRtp, UInt32(100 + PhoneFrameTimingLog.capacity + 4), "oldest first")
    }

    func testPhoneReceiverTimesMacDisplayToDecodeOnTheSyncedClock() throws {
        let log = PhoneFrameTimingLog()
        let receiver = FrameTimingReceiver(log: log)
        let offset: UInt32 = 3_000_000_000
        let clock = ClockSyncEstimate(offsetMs: 500, uncertaintyMs: 2, samples: 3)
        let hosts = sizes.enumerated().map { index, bytes in
            host(UInt32(index * 1_500), bytes, display: index == 2 ? 0 : 10_000 + Double(index) * 16,
                 encoded: 10_020 + Double(index) * 16)
        }
        for record in hosts {
            let decodedOnPhone = (record.isResend ? record.encodedMs : record.displayMs + 40) - 500
            log.received(wireRtp: record.localRtp &+ offset, bytes: record.bytes, atMs: decodedOnPhone - 5)
            log.decoded(rtp: Int32(bitPattern: record.localRtp &+ offset), atMs: decodedOnPhone)
        }
        XCTAssertNil(receiver.drain(), "no fields before the Mac sends records")
        receiver.receive(FrameTimingRecords(hosts), clock: clock)
        let drain = try XCTUnwrap(receiver.drain())
        XCTAssertTrue(drain.locked)
        XCTAssertEqual(drain.count, hosts.count - 1, "the re-send joins but is not timed")
        XCTAssertEqual(drain.p50Ms ?? 0, 40, accuracy: 0.2)
        XCTAssertEqual(receiver.joinedFrames, hosts.count)
    }

    func testPhoneBookkeepingStopsWhileTheMacSendsNoRecords() {
        let log = PhoneFrameTimingLog()
        let receiver = FrameTimingReceiver(log: log)
        XCTAssertTrue(log.isActive)
        receiver.receive(nil, clock: nil)
        XCTAssertFalse(log.isActive)
        log.received(wireRtp: 1, bytes: 1, atMs: 1)
        XCTAssertTrue(log.snapshot().isEmpty)
        receiver.receive(FrameTimingRecords([host(1, 1)]), clock: nil)
        XCTAssertTrue(log.isActive)
    }

    // MARK: Switch

    func testFrameTimingSwitchDefaultsOnAndIsListedForCleanup() throws {
        XCTAssertTrue(StreamTuning.tuned.frameTiming)
        XCTAssertFalse(StreamTuning.legacy.frameTiming)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.frameTimingKey))
        XCTAssertFalse(StreamTuning.tuned.summary.contains("frame timing"))
        let suite = "FrameTimingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: StreamTuning.frameTimingKey)
        let off = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(off.frameTiming)
        XCTAssertTrue(off.summary.contains("no frame timing"), off.summary)
        defaults.set(true, forKey: StreamTuning.legacyDefaultsKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), .legacy)
    }

    // MARK: Loopback proof

    /// Two in-process PeerMedia stream 60 fps synthetic frames; the host summary is forwarded to the
    /// phone as the capture status would carry it. Same Mac, so the clock offset is zero.
    @MainActor
    func testLoopbackJoinsHostRecordsToPhoneDecodes() async throws {
        let on = try await loopback(frameTiming: true, seconds: 3.5)
        let off = try await loopback(frameTiming: false, seconds: 3.5)
        print(String(format: "FRAME TIMING LOOPBACK on: rendered %d, decoder saw %d/%d, host records %d in %d summaries, "
                     + "joined %d, timed %d, ≥0 %d, lock after %.2fs, host p50 %.1f p95 %.1f, to phone p50 %.1f p95 %.1f · off: rendered %d",
                     on.rendered, on.decoderReceived, on.decoderDecoded, on.records, on.summariesWithRecords,
                     on.joined, on.timed, on.nonNegative, on.lockSeconds ?? -1, on.hostP50 ?? -1, on.hostP95 ?? -1,
                     on.phoneP50 ?? -1, on.phoneP95 ?? -1, off.rendered))
        XCTAssertGreaterThan(on.summariesWithRecords, 0, "the host summary carries records")
        XCTAssertNotNil(on.hostP50)
        XCTAssertGreaterThan(on.decoderReceived, 100, "the decoder wrapper sees the frames")
        XCTAssertGreaterThanOrEqual(on.decoderDecoded, on.rendered - 2, "every rendered frame passed through the wrapper")
        XCTAssertNotNil(on.lockSeconds, "the join locks")
        XCTAssertGreaterThan(on.joined, on.records / 2)
        XCTAssertGreaterThanOrEqual(Double(on.nonNegative), 0.8 * Double(on.joined - on.resendsJoined),
                                    "frame → phone is finite and non-negative for most joined frames")
        XCTAssertNotNil(on.phoneP50)
        XCTAssertEqual(off.summariesWithRecords, 0, "switch off sends no records")
        XCTAssertNil(off.hostP50)
        XCTAssertEqual(Double(on.rendered), Double(off.rendered), accuracy: max(20, 0.2 * Double(off.rendered)),
                       "decoded frames are unaffected by the switch")
    }

    private struct LoopbackResult {
        var rendered = 0
        var decoderReceived = 0
        var decoderDecoded = 0
        var summariesWithRecords = 0
        var records = 0
        var resendsJoined = 0
        var joined = 0
        var timed = 0
        var nonNegative = 0
        var lockSeconds: Double?
        var hostP50: Double?
        var hostP95: Double?
        var phoneP50: Double?
        var phoneP95: Double?
    }

    @MainActor
    private func loopback(frameTiming: Bool, seconds: Double) async throws -> LoopbackResult {
        FrameTimingSwitch.override = frameTiming
        let host = PeerMedia(isHost: true, servers: [])
        FrameTimingSwitch.override = nil
        let phone = PeerMedia(isHost: false, servers: [])
        defer { host.close(); phone.close() }
        XCTAssertEqual(host.frameTimingLog != nil, frameTiming)
        let receiver = try XCTUnwrap(phone.frameTimingReceiver)
        phone.counters.clockUpdated(ClockSyncEstimate(offsetMs: 0, uncertaintyMs: 0, samples: 1))
        host.onSignal = { [weak phone] signal in phone?.receive(signal) }
        phone.onSignal = { [weak host] signal in host?.receive(signal) }
        var hostConnected = false, phoneConnected = false
        host.onState = { if $0 == "connected" { hostConnected = true } }
        phone.onState = { if $0 == "connected" { phoneConnected = true } }
        var track: RTCVideoTrack?
        phone.onRemoteVideo = { track = $0 }
        var result = LoopbackResult()
        var hostP50s: [Double] = [], hostP95s: [Double] = [], phoneP50s: [Double] = [], phoneP95s: [Double] = []
        var streamStart: Date?
        host.onSenderStatistics = { [weak host, weak phone] _ in
            guard let summary = host?.takeHostSummary() else { return }
            if let records = summary.frameRecords {
                result.summariesWithRecords += 1
                result.records += records.rtp.count
            }
            phone?.acceptHostSummary(summary, arrivedFrames: nil, arrivedAt: nil)
            if let p50 = summary.frameHostP50Ms { hostP50s.append(p50) }
            if let p95 = summary.frameHostP95Ms { hostP95s.append(p95) }
        }
        phone.onStreamStatistics = { report in
            if report.frameJoinLocked == true, result.lockSeconds == nil, let streamStart {
                result.lockSeconds = Date().timeIntervalSince(streamStart)
            }
            if let p50 = report.frameToPhoneP50Ms { phoneP50s.append(p50) }
            if let p95 = report.frameToPhoneP95Ms { phoneP95s.append(p95) }
        }
        host.offer()
        let deadline = Date().addingTimeInterval(20)
        while !(hostConnected && phoneConnected && track != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let remote = try XCTUnwrap(track, "loopback peers connected")
        let counter = RenderCounter()
        remote.add(counter)
        defer { remote.remove(counter) }

        let frames = try (0..<24).map { try Self.frame(index: $0) }
        let pump = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "frame-timing.pump", qos: .userInteractive))
        var index = 0
        pump.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
        pump.setEventHandler { [weak host] in
            let resend = index % 20 == 19
            let buffer = frames[(resend ? index - 1 : index) % frames.count]
            let now = ProcessInfo.processInfo.systemUptime
            host?.pushFrame(buffer, timeStampNs: Int64(now * 1_000_000_000), displayMs: resend ? 0 : MachClock.nowMs() - 3)
            index += 1
        }
        streamStart = Date()
        pump.resume()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        pump.cancel()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        result.rendered = counter.count
        let counts = receiver.log.counts
        result.decoderReceived = counts.received
        result.decoderDecoded = counts.decoded
        result.joined = receiver.joinedFrames
        result.resendsJoined = receiver.joinedResends
        result.timed = receiver.timedFrames
        result.nonNegative = receiver.nonNegativeFrames
        result.hostP50 = Self.median(hostP50s)
        result.hostP95 = Self.median(hostP95s)
        result.phoneP50 = Self.median(phoneP50s)
        result.phoneP95 = Self.median(phoneP95s)
        return result
    }

    private static func median(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    /// Gray with a few bright blocks placed per index, so frame sizes vary.
    private static func frame(index: Int) throws -> CVPixelBuffer {
        let width = 640, height = 416
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, plane == 0 ? 90 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var seed = UInt32(truncatingIfNeeded: index &* 2_654_435_761 &+ 12_345)
        for _ in 0..<(3 + index % 5) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let x = Int(seed % UInt32(width - 80)), y = Int((seed >> 12) % UInt32(height - 60))
            let size = 20 + Int((seed >> 20) % 60)
            for row in y..<min(height, y + size) {
                for column in x..<min(width, x + size) { luma[row * stride + column] = UInt8((column * 7 + row * 3 + index * 11) & 0xff) }
            }
        }
        return buffer
    }
}

private final class RenderCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock(); frames += 1; lock.unlock()
    }
}
