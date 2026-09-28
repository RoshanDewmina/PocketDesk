import XCTest
import CoreVideo
import WebRTC

/// Opt-in loopback benchmark: real negotiated encode/decode through two
/// in-process PeerMedia instances on this Mac. It measures pipeline behaviour
/// (codec level, encoder rate and jitter buffer), not
/// Wi-Fi or iPhone decode/display.
/// Run: POCKETDESK_STREAM_BENCH=1 xcrun xctest -XCTest StreamLoopbackBenchmarkTests <bundle>
final class StreamLoopbackBenchmarkTests: XCTestCase {
    private static let markerBits = 5
    private static let markerBlock = 64

    @MainActor
    func testLoopbackStreamingPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["POCKETDESK_STREAM_BENCH"] == "1" else {
            throw XCTSkip("Set POCKETDESK_STREAM_BENCH=1 to run the loopback streaming benchmark.")
        }
        let seconds = Double(environment["POCKETDESK_BENCH_SECONDS"] ?? "") ?? 8
        let sizes: [(Int, Int)] = environment["POCKETDESK_BENCH_SIZES"].map { value in
            value.split(separator: ",").compactMap { item in
                let parts = item.split(separator: "x").compactMap { Int($0) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        } ?? [(2940, 1912), (1920, 1248)]

        let logger = RTCCallbackLogger()
        logger.severity = .info
        var webrtcNotes: [String] = []
        let notesLock = NSLock()
        logger.start { message in
            let interesting = ["RTCVideoEncoderH264", "video_stream_encoder.cc", "encoder_switch", "EncoderSwitch",
                               "PlayoutDelay", "Negotiated codec", "overuse", "fallback", "Fallback"]
            guard interesting.contains(where: { message.contains($0) }) else { return }
            notesLock.lock(); if webrtcNotes.count < 400 { webrtcNotes.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }; notesLock.unlock()
        }
        defer { logger.stop() }

        for (width, height) in sizes {
            try await run(width: width, height: height, seconds: seconds)
        }
        notesLock.lock()
        for note in webrtcNotes where !note.contains("Encoder info changed") { print("WEBRTC NOTE: \(note.prefix(300))") }
        notesLock.unlock()
    }

    @MainActor
    private func run(width: Int, height: Int, seconds: Double) async throws {
        let host = PeerMedia(isHost: true, servers: [])
        let compatibleReceiver = ProcessInfo.processInfo.environment["POCKETDESK_BENCH_COMPATIBLE_RECEIVER"] == "1"
        let phone = PeerMedia(isHost: false, servers: [], nativeDesktopCodecs: !compatibleReceiver)
        defer { host.close(); phone.close() }
        host.onSignal = { [weak phone] signal in phone?.receive(signal) }
        phone.onSignal = { [weak host] signal in host?.receive(signal) }
        var hostConnected = false, phoneConnected = false
        host.onState = { if $0 == "connected" { hostConnected = true } }
        phone.onState = { if $0 == "connected" { phoneConnected = true } }
        var track: RTCVideoTrack?
        phone.onRemoteVideo = { track = $0 }
        host.captureMaximumDimension = max(width, height)
        var hostReports: [StreamStatsReport] = []
        var phoneReports: [StreamStatsReport] = []
        host.onStreamStatistics = { hostReports.append($0) }
        phone.onStreamStatistics = { phoneReports.append($0) }
        host.offer()

        let deadline = Date().addingTimeInterval(20)
        while !(hostConnected && phoneConnected && track != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(hostConnected && phoneConnected, "loopback peers connected")
        let remote = try XCTUnwrap(track)
        _ = remote

        let frames = try (0..<(1 << Self.markerBits)).map { try Self.makeFrame(width: width, height: height, index: $0) }
        let pump = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "bench.pump", qos: .userInteractive))
        var index = 0
        pump.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
        pump.setEventHandler {
            let slot = index % frames.count
            let now = ProcessInfo.processInfo.systemUptime
            host.counters.captured(idle: false)
            host.pushFrame(frames[slot], timeStampNs: Int64(now * 1_000_000_000))
            index += 1
        }
        pump.resume()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        pump.cancel()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let steadyHost = Array(hostReports.dropFirst(3))
        let steadyPhone = Array(phoneReports.dropFirst(3))
        func median(_ values: [Double?]) -> String {
            let sorted = values.compactMap { $0 }.sorted()
            guard !sorted.isEmpty else { return "–" }
            return String(format: "%.1f", sorted[sorted.count / 2])
        }
        let last = steadyHost.last ?? hostReports.last
        let lastPhone = steadyPhone.last ?? phoneReports.last
        XCTAssertTrue(phoneReports.contains { ($0.decodedFPS ?? 0) > 0 }, "receiver decoded the generated stream")
        if compatibleReceiver, let decodedWidth = lastPhone?.receivedWidth, let decodedHeight = lastPhone?.receivedHeight {
            let limit = H264FrameBudget.level(31)
            XCTAssertLessThanOrEqual(((decodedWidth + 15) / 16) * ((decodedHeight + 15) / 16) * 60, limit.macroblocksPerSecond)
        }
        print("""
        BENCH RECEIPT \(width)x\(height) \(Int(seconds))s: \
        level=\(last?.h264ProfileLevel ?? "?") encoder=\(last?.encoderImplementation ?? "?") \
        sent=\(last?.sentWidth ?? 0)x\(last?.sentHeight ?? 0) limit=\(last?.qualityLimitation ?? "?") \
        pushedFPS=\(median(steadyHost.map { $0.pushedFPS })) encodedFPS=\(median(steadyHost.map { $0.encodedFPS })) \
        sentFPS=\(median(steadyHost.map { $0.sentFPS })) encodeMs=\(median(steadyHost.map { $0.encodeMs })) \
        sentKbps=\(median(steadyHost.map { $0.sentKbps })) targetKbps=\(median(steadyHost.map { $0.targetKbps })) \
        qp=\(median(steadyHost.map { $0.qpAverage })) | \
        recvFPS=\(median(steadyPhone.map { $0.receivedFPS })) decodedFPS=\(median(steadyPhone.map { $0.decodedFPS })) \
        renderedFPS=\(median(steadyPhone.map { $0.renderedFPS })) gapP90=\(median(steadyPhone.map { $0.renderGapP90Ms })) \
        gapMax=\(median(steadyPhone.map { $0.renderGapMaxMs })) jitterBufMs=\(median(steadyPhone.map { $0.jitterBufferMs })) \
        decodeMs=\(median(steadyPhone.map { $0.decodeMs })) dropped=\(lastPhone?.framesDropped ?? 0)
        """)
        for report in hostReports + phoneReports { print(report.logLine) }
    }

    private static func makeFrame(width: Int, height: Int, index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0x1234_5678
        for y in 0..<height {
            let row = luma + y * lumaStride
            let textLine = (y / 18) % 3 != 2 && (y % 18) > 3 && (y % 18) < 15
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let glyph = textLine && ((x / 9) % 7 != 6) && (seed >> 28) > 6
                row[x] = glyph ? 40 : 225
            }
        }
        let windowX = (index * 37) % max(1, width - 640)
        let windowY = 200 + (index * 11) % max(1, height - 700)
        for y in windowY..<min(height, windowY + 480) {
            let row = luma + y * lumaStride
            for x in windowX..<min(width, windowX + 640) { row[x] = UInt8(truncatingIfNeeded: 60 + (x + y + index * 9) % 160) }
        }
        for bit in 0..<markerBits {
            let on = (index >> bit) & 1 == 1
            for y in 0..<markerBlock {
                let row = luma + y * lumaStride
                for x in (bit * markerBlock)..<((bit + 1) * markerBlock) { row[x] = on ? 235 : 16 }
            }
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<(height / 2) { memset(chroma + y * chromaStride, 128, chromaStride) }
        return buffer
    }

}
