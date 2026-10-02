import XCTest
import MetricKit

final class CrashDiagnosticsTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testDefaultOnAndExplicitNoAreSnapshottedBeforeAnySubscriberStarts() throws {
        let suite = "MetricKitTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeCrashDiagnosticSource()
        let service = CrashDiagnostics(defaults: defaults, store: CrashDiagnosticStore(directory: dir), source: { source })
        XCTAssertTrue(service.enabled); XCTAssertEqual(source.starts, 0)
        service.start(); service.start(); XCTAssertEqual(source.starts, 1)
        defaults.set(false, forKey: CrashDiagnostics.defaultsKey)
        XCTAssertTrue(service.enabled, "Changing the preference requires a new process/service")
        let disabledSource = FakeCrashDiagnosticSource()
        let disabled = CrashDiagnostics(defaults: defaults, store: CrashDiagnosticStore(directory: dir), source: { disabledSource })
        disabled.start(); XCTAssertFalse(disabled.enabled); XCTAssertEqual(disabledSource.starts, 0)
        service.stop(); XCTAssertEqual(source.stops, 1)
        source.deliver?(.init(kind: .hang, begin: Date(), end: Date(), stack: .empty))
        XCTAssertTrue(service.reports().isEmpty, "A late callback after stop is fenced")
        defaults.set(true, forKey: CrashDiagnostics.defaultsKey)
        XCTAssertTrue(CrashDiagnostics(defaults: defaults, store: CrashDiagnosticStore(directory: dir), source: { disabledSource }).enabled)
    }

    func testRealLegacySubscriberCallbackRetainsSanitizedStackAndExplicitExport() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var registered: MXMetricManagerSubscriber?
        var adds = 0, removes = 0
        let source = LegacyCrashDiagnosticSource(add: { registered = $0; adds += 1 }, remove: { _ in removes += 1 })
        let service = CrashDiagnostics(enabled: true, store: CrashDiagnosticStore(directory: dir), source: { source })
        service.start(); XCTAssertEqual(adds, 1)
        let subscriber = try XCTUnwrap(registered)
        subscriber.didReceive?([FixtureDiagnosticPayload()] as [MXDiagnosticPayload])
        let report = try XCTUnwrap(service.reports().first)
        XCTAssertEqual(report.event.kind, .crash)
        XCTAssertEqual(report.artifact, .current)
        XCTAssertEqual(report.event.signal, 11)
        XCTAssertEqual(report.event.stack.frames.count, 2)
        XCTAssertEqual(report.event.stack.frames[1].parent, 0)
        XCTAssertEqual(report.event.stack.frames[0].offsetIntoBinaryTextSegment, 165304)
        XCTAssertEqual(report.event.stack.frames[0].binaryUUID?.uuidString, "70B89F27-1634-3580-A695-57CDB41D7743")
        let exported = try XCTUnwrap(service.export(id: report.id))
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        for secret in ["sdp", "room-secret", "192.0.2.1", "binaryName", "address", "exceptionReason", "/private"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertEqual(try JSONDecoder().decode(CrashDiagnosticReport.self, from: exported), report)
        service.delete(report.id); XCTAssertTrue(service.reports().isEmpty)
        XCTAssertNil(service.export(id: report.id))
        service.stop(); XCTAssertEqual(removes, 1)
        subscriber.didReceive?([FixtureDiagnosticPayload()] as [MXDiagnosticPayload])
        XCTAssertTrue(service.reports().isEmpty)
    }

    func testCountAgeByteAndCorruptFileRetentionUseRealFiles() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = CrashDiagnosticStore(directory: dir, now: { now })
        for index in 0..<15 {
            now = now.addingTimeInterval(1)
            try store.save(.init(kind: .hang, begin: now, end: now, stack: .empty, durationSeconds: Double(index)))
        }
        XCTAssertEqual(store.load().count, CrashDiagnosticStore.maximumReports)
        XCTAssertEqual(store.load().first?.event.durationSeconds, 14)
        let bad = dir.appendingPathComponent("bad.json")
        try Data(repeating: 65, count: CrashDiagnosticStore.maximumReportBytes + 1).write(to: bad)
        _ = store.load(); XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        let future = CrashDiagnosticReport(id: UUID(), createdAt: now.addingTimeInterval(10), event: .init(kind: .crash, begin: now, end: now, stack: .empty))
        try JSONEncoder().encode(future).write(to: dir.appendingPathComponent(future.id.uuidString + ".json"))
        XCTAssertEqual(store.load().count, CrashDiagnosticStore.maximumReports)
        // Older tiny reports can fill count slots skipped by the byte budget. Use
        // only large reports to make the aggregate byte cap the limiting factor.
        store.deleteAll()
        let large = CrashDiagnosticStack(callStackPerThread: true, threads: [.init(threadAttributed: true)], frames: (0..<CrashDiagnosticStack.maximumFrames).map {
            .init(thread: 0, parent: $0 == 0 ? nil : 0, binaryUUID: UUID(), offsetIntoBinaryTextSegment: UInt64.max, sampleCount: Int.max)
        }, truncated: false)
        for _ in 0..<12 { now = now.addingTimeInterval(1); try store.save(.init(kind: .cpuException, begin: now, end: now, stack: large)) }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        XCTAssertLessThanOrEqual(bytes, CrashDiagnosticStore.maximumTotalBytes)
        XCTAssertLessThan(store.load().count, CrashDiagnosticStore.maximumReports, "Total bytes also caps retention")
        now = now.addingTimeInterval(CrashDiagnosticStore.retention + 1)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: []).isEmpty)
    }

    func testForgedArtifactAndUnknownExportFieldsAreRejectedOrDiscarded() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let store = CrashDiagnosticStore(directory: dir)
        try store.save(.init(kind: .crash, begin: now, end: now, stack: .empty))
        let report = try XCTUnwrap(store.load().first)
        let file = dir.appendingPathComponent(report.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["room"] = "room-secret"
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertFalse(String(decoding: try XCTUnwrap(store.export(id: report.id)), as: UTF8.self).contains("room-secret"))
        json["artifact"] = ["platform": "mac", "version": "sdp 192.0.2.1", "build": "1", "os": [27, 0, 0]]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStackDepthFrameAndInputByteBoundsDiscardUnknownFields() throws {
        var node: [String: Any] = ["binaryUUID": "not-a-uuid", "offsetIntoBinaryTextSegment": -2, "sampleCount": -1, "address": "192.0.2.1"]
        for _ in 0..<100 { node = ["subFrames": [node]] }
        let data = try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStackPerThread": true, "callStacks": [["threadAttributed": true, "callStackRootFrames": [node]]]]])
        let stack = CrashDiagnosticStack.legacyJSON(data)
        XCTAssertTrue(stack.truncated); XCTAssertLessThanOrEqual(stack.frames.count, CrashDiagnosticStack.maximumDepth)
        XCTAssertTrue(stack.frames.allSatisfy { $0.binaryUUID == nil && $0.offsetIntoBinaryTextSegment == nil && $0.sampleCount == nil })
        XCTAssertTrue(CrashDiagnosticStack.legacyJSON(Data(repeating: 0, count: CrashDiagnosticStack.maximumInputBytes + 1)).truncated)
        let roots = Array(repeating: ["sampleCount": 1], count: 1000)
        let wide = CrashDiagnosticStack.legacyJSON(try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStacks": [["callStackRootFrames": roots]]]]))
        XCTAssertEqual(wide.frames.count, CrashDiagnosticStack.maximumFrames); XCTAssertTrue(wide.truncated)
    }

    func testLegacyCallbackConvertsAllFourDiagnosticKindsAndNormalizesMeasurementUnits() throws {
        let source = LegacyCrashDiagnosticSource(add: { _ in }, remove: { _ in })
        var events: [CrashDiagnosticEvent] = []
        source.start { events.append($0) }
        source.didReceive([FixtureDiagnosticPayload(allKinds: true)])
        XCTAssertEqual(events.map(\.kind), [.crash, .hang, .cpuException, .diskWriteException])
        XCTAssertEqual(events[1].durationSeconds, 1.5)
        XCTAssertEqual(events[2].cpuSeconds, 2)
        XCTAssertEqual(events[2].sampledSeconds, 3)
        XCTAssertEqual(events[3].bytesWritten, 1024)
        XCTAssertTrue(events.allSatisfy { $0.stack.frames.count == 2 })
        XCTAssertNoThrow(try events.forEach { try $0.validate() })
        source.stop()
    }

    func testMalformedEventsFailClosedAndSymlinksNeverReadOrOverwriteTheirTarget() throws {
        let dir = directory(), target = directory(); defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: target) }
        let now = Date()
        let store = CrashDiagnosticStore(directory: dir)
        XCTAssertThrowsError(try store.save(.init(kind: .hang, begin: now, end: now, stack: .empty, durationSeconds: .nan)))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(.init(kind: .hang, begin: now, end: now, stack: .empty)))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: []).isEmpty)
    }

    func testModernTypedReportConversionKeepsOffsetsAndUnitsAndDiscardsPrivateContext() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Typed MetricKit reports require OS27") }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let tree = try decoder.decode(CallStackTree.self, from: Data(#"{"callStackPerThread":true,"callStackThreads":[{"threadAttributed":true,"rootFrames":[{"binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":165304,"address":7170766264,"sampleCount":1,"subFrames":[{"offsetIntoBinaryTextSegment":12,"sampleCount":2,"subFrames":[]}]}]}],"binaryInfo":[]}"#.utf8))
        let stack = CrashDiagnosticStack.modern(tree)
        XCTAssertEqual(stack.frames.count, 2)
        XCTAssertEqual(stack.frames[0].binaryUUID?.uuidString, "70B89F27-1634-3580-A695-57CDB41D7743")
        XCTAssertEqual(stack.frames[1].parent, 0)
        XCTAssertEqual(stack.frames[1].offsetIntoBinaryTextSegment, 12)
        XCTAssertEqual(stack.threads.first?.threadAttributed, true)
        let treeJSON = try JSONSerialization.jsonObject(with: encoder.encode(tree))
        func measurement<UnitType>(_ value: Double, _ unit: UnitType) throws -> Any where UnitType: Dimension {
            // MetricKit's typed report schema uses a unit symbol string, unlike
            // Foundation Measurement's standalone Codable representation.
            ["value": value, "unit": unit.symbol]
        }
        let crash = try decoder.decode(CrashDiagnostic.self, from: JSONSerialization.data(withJSONObject: ["callStackTree": treeJSON, "signal": 11, "exceptionType": 1, "virtualMemoryRegionInfo": "192.0.2.1 room-secret"]))
        let hang = try decoder.decode(HangDiagnostic.self, from: JSONSerialization.data(withJSONObject: ["callStackTree": treeJSON, "hangDuration": try measurement(1500, UnitDuration.milliseconds)]))
        let cpu = try decoder.decode(CPUExceptionDiagnostic.self, from: JSONSerialization.data(withJSONObject: ["callStackTree": treeJSON, "totalCPUTime": try measurement(2000, UnitDuration.milliseconds), "totalSampledTime": try measurement(3000, UnitDuration.milliseconds)]))
        let disk = try decoder.decode(DiskWriteExceptionDiagnostic.self, from: JSONSerialization.data(withJSONObject: ["callStackTree": treeJSON, "totalBytesWritten": try measurement(1024, UnitInformationStorage.bytes)]))
        let environment = try decoder.decode(DiagnosticReport.Environment.self, from: Data(#"{"regionFormat":"room-secret","osVersion":{"platform":"macOS","number":"27.0","buildNumber":"26A434"},"deviceType":"room-secret","platformArchitecture":"arm64","lowPowerModeEnabled":false,"isTestFlightApp":false,"applicationVersion":"1.0","applicationBuildVersion":"123","bundleIdentifier":"room-secret","signpostData":[],"states":[]}"#.utf8))
        let range = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 10)
        var events: [CrashDiagnosticEvent] = []
        for result in [DiagnosticResult.crash(crash), .hang(hang), .cpuException(cpu), .diskWriteException(disk)] {
            // DiagnosticReport flattens the SDK's tagged result and uses
            // reference-date seconds under begin/end for its time range.
            var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
            json["timeRange"] = ["begin": range.start.timeIntervalSinceReferenceDate,
                "end": range.end.timeIntervalSinceReferenceDate]
            json["environment"] = try JSONSerialization.jsonObject(with: encoder.encode(environment))
            let report = try decoder.decode(DiagnosticReport.self, from: JSONSerialization.data(withJSONObject: json))
            let event = try XCTUnwrap(ModernCrashDiagnosticSource.event(report))
            try event.validate(); events.append(event)
            XCTAssertEqual(event.begin, range.start)
            XCTAssertEqual(event.end, range.end)
            let exported = String(decoding: try encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(exported.contains("address")); XCTAssertFalse(exported.contains("7170766264"))
            XCTAssertFalse(exported.contains("192.0.2.1")); XCTAssertFalse(exported.contains("room-secret"))
            XCTAssertEqual(event.stack, stack)
        }
        XCTAssertEqual(events.map(\.kind), [.crash, .hang, .cpuException, .diskWriteException])
        XCTAssertEqual(events[0].signal, 11); XCTAssertEqual(events[0].exceptionType, 1)
        XCTAssertEqual(events[1].durationSeconds, 1.5)
        XCTAssertEqual(events[2].cpuSeconds, 2); XCTAssertEqual(events[2].sampledSeconds, 3)
        XCTAssertEqual(events[3].bytesWritten, 1024)
    }
}

private final class FakeCrashDiagnosticSource: CrashDiagnosticSource {
    var starts = 0, stops = 0
    var deliver: ((CrashDiagnosticEvent) -> Void)?
    func start(_ receive: @escaping (CrashDiagnosticEvent) -> Void) { starts += 1; deliver = receive }
    func stop() { stops += 1 }
}

private final class FixtureCallStack: MXCallStackTree {
    override func jsonRepresentation() -> Data {
        Data(#"{"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":165304,"sampleCount":1,"binaryName":"/private/room-secret","address":"192.0.2.1","sdp":"secret","subFrames":[{"offsetIntoBinaryTextSegment":12,"sampleCount":2}]}]}]}}"#.utf8)
    }
}

private final class FixtureCrash: MXCrashDiagnostic {
    override var callStackTree: MXCallStackTree { FixtureCallStack() }
    override var signal: NSNumber? { 11 }
    override var exceptionType: NSNumber? { 1 }
    override var terminationReason: String? { "room-secret sdp 192.0.2.1" }
}

private final class FixtureDiagnosticPayload: MXDiagnosticPayload {
    private let allKinds: Bool
    init(allKinds: Bool = false) { self.allKinds = allKinds; super.init() }
    required init?(coder: NSCoder) { fatalError("Not used by fixtures") }
    override var timeStampBegin: Date { Date().addingTimeInterval(-5) }
    override var timeStampEnd: Date { Date() }
    override var crashDiagnostics: [MXCrashDiagnostic]? { [FixtureCrash()] }
    override var hangDiagnostics: [MXHangDiagnostic]? { allKinds ? [FixtureHang()] : nil }
    override var cpuExceptionDiagnostics: [MXCPUExceptionDiagnostic]? { allKinds ? [FixtureCPU()] : nil }
    override var diskWriteExceptionDiagnostics: [MXDiskWriteExceptionDiagnostic]? { allKinds ? [FixtureDiskWrite()] : nil }
}

private final class FixtureHang: MXHangDiagnostic {
    override var callStackTree: MXCallStackTree { FixtureCallStack() }
    override var hangDuration: Measurement<UnitDuration> { .init(value: 1500, unit: .milliseconds) }
}

private final class FixtureCPU: MXCPUExceptionDiagnostic {
    override var callStackTree: MXCallStackTree { FixtureCallStack() }
    override var totalCPUTime: Measurement<UnitDuration> { .init(value: 2000, unit: .milliseconds) }
    override var totalSampledTime: Measurement<UnitDuration> { .init(value: 3000, unit: .milliseconds) }
}

private final class FixtureDiskWrite: MXDiskWriteExceptionDiagnostic {
    override var callStackTree: MXCallStackTree { FixtureCallStack() }
    override var totalWritesCaused: Measurement<UnitInformationStorage> { .init(value: 1024, unit: .bytes) }
}
