import XCTest
import CoreText
import CoreVideo
import WebRTC

/// Opt-in loopback benchmark: real negotiated encode/decode through two
/// in-process PeerMedia instances on this Mac. It measures pipeline behaviour
/// (codec level, encoder rate, pacing, jitter buffer, push→decoded latency and
/// decoded sharpness), not Wi-Fi, ScreenCaptureKit or iPhone decode/display.
///
/// Run one tuning per process because WebRTC field trials are process-wide:
/// POCKETDESK_STREAM_BENCH=1 [POCKETDESK_BENCH_TUNING=legacy|tuned] \
///   [POCKETDESK_BENCH_SCENES=window,scroll,jump] [POCKETDESK_BENCH_SIZES=2560x1664,1920x1248] \
///   xcrun xctest -XCTest RemoteCoreTests.StreamLoopbackBenchmarkTests <bundle>
/// Individual overrides: POCKETDESK_BENCH_PLAYOUT=none|min,max  POCKETDESK_BENCH_BITRATES=0|1
///   POCKETDESK_BENCH_LAN_HEADROOM=1|2  POCKETDESK_BENCH_MAX_IN_FLIGHT=0|1|2
/// POCKETDESK_BENCH_DEGRADATION=none|framerate|resolution|balanced
final class StreamLoopbackBenchmarkTests: XCTestCase {
    fileprivate static let markerBits = 5
    fileprivate static let markerBlock = 64
    /// 32 frames x 17 px = 544 px, two periods of the rendered page (8 lines x 34 px), so the scroll
    /// loop is seamless: continuous 1,020 px/s scrolling with no full-screen jump when it wraps.
    private static let scrollStep = 17

    @MainActor
    func testLoopbackStreamingPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["POCKETDESK_STREAM_BENCH"] == "1" else {
            throw XCTSkip("Set POCKETDESK_STREAM_BENCH=1 to run the loopback streaming benchmark.")
        }
        let tuning = Self.tuning(from: environment)
        XCTAssertTrue(StreamTuning.override(tuning), "benchmark must choose the tuning before any factory exists")
        let seconds = Double(environment["POCKETDESK_BENCH_SECONDS"] ?? "") ?? 8
        let sizes: [(Int, Int)] = environment["POCKETDESK_BENCH_SIZES"].map { value in
            value.split(separator: ",").compactMap { item in
                let parts = item.split(separator: "x").compactMap { Int($0) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        } ?? [(2560, 1664), (1920, 1248)]
        let scenes = (environment["POCKETDESK_BENCH_SCENES"] ?? "window,scroll,jump").split(separator: ",").map(String.init)

        let logger = RTCCallbackLogger()
        logger.severity = .info
        let notes = NoteCollector()
        logger.start { message in
            let interesting = ["RTCVideoEncoderH264", "video_stream_encoder.cc", "encoder_switch", "EncoderSwitch",
                               "PlayoutDelay", "Negotiated codec", "overuse", "fallback", "Fallback", "field_trial",
                               "SetStartBitrate", "low_latency"]
            guard interesting.contains(where: { message.contains($0) }) else { return }
            notes.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer { logger.stop() }

        print("BENCH TUNING \(StreamTuning.current.summary)")
        if environment["POCKETDESK_BENCH_TRACE"] == "1" {
            let start = ProcessInfo.processInfo.systemUptime
            DesktopH264Encoder.trace = { print(String(format: "ENCODER %.2fs ", ProcessInfo.processInfo.systemUptime - start) + $0) }
        }
        defer { DesktopH264Encoder.trace = nil }
        for scene in scenes {
            for (width, height) in sizes {
                try await run(scene: scene, width: width, height: height, seconds: seconds)
            }
        }
        for note in notes.drain() where !note.contains("Encoder info changed") { print("WEBRTC NOTE: \(note.prefix(300))") }
    }

    private static func tuning(from environment: [String: String]) -> StreamTuning {
        var tuning = environment["POCKETDESK_BENCH_TUNING"] == "legacy" ? StreamTuning.legacy : StreamTuning.tuned
        if let playout = environment["POCKETDESK_BENCH_PLAYOUT"] {
            let values = playout.split(separator: ",").compactMap { Int($0) }
            tuning.playoutDelayMinMs = values.count == 2 ? values[0] : nil
            tuning.playoutDelayMaxMs = values.count == 2 ? values[1] : nil
        }
        if let bitrates = environment["POCKETDESK_BENCH_BITRATES"] { tuning.qualityBitrates = bitrates == "1" }
        if let refresh = environment["POCKETDESK_BENCH_REFRESH"] { tuning.encoderRestart = refresh == "1" }
        if let headroom = environment["POCKETDESK_BENCH_BWE_HEADROOM"].flatMap(Int.init) { tuning.bandwidthHeadroom = headroom }
        if let headroom = environment["POCKETDESK_BENCH_LAN_HEADROOM"].flatMap(Double.init) { tuning.lanBandwidthHeadroom = headroom }
        if let limit = environment["POCKETDESK_BENCH_MAX_IN_FLIGHT"].flatMap(Int.init) {
            tuning.encoderMaxInFlight = limit > 0 ? limit : nil
            // Matched baseline 1 uses the exact pre-pipeline path, including key preemption.
            tuning.encoderPipelining = limit == 2
        }
        if let pacing = environment["POCKETDESK_BENCH_PACING"] { tuning.videoPacing = pacing == "none" ? nil : pacing }
        switch environment["POCKETDESK_BENCH_DEGRADATION"] {
        case "none": tuning.degradationPreference = nil
        case "framerate": tuning.degradationPreference = .maintainFramerate
        case "resolution": tuning.degradationPreference = .maintainResolution
        case "balanced": tuning.degradationPreference = .balanced
        default: break
        }
        return tuning
    }

    @MainActor
    private func run(scene: String, width: Int, height: Int, seconds: Double) async throws {
        let host = PeerMedia(isHost: true, servers: [])
        let compatibleReceiver = ProcessInfo.processInfo.environment["POCKETDESK_BENCH_COMPATIBLE_RECEIVER"] == "1"
        let phone = PeerMedia(isHost: false, servers: [], nativeDesktopCodecs: !compatibleReceiver)
        defer { host.close(); phone.close() }
        host.applyStreamQuality(max(width, height) > 1920 ? .sharp : .balanced)
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

        let frames = try Self.makeFrames(scene: scene, width: width, height: height)
        let probe = LatencyProbe(sources: frames)
        remote.add(probe); defer { remote.remove(probe) }
        let pump = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "bench.pump", qos: .userInteractive))
        var index = 0
        pump.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
        pump.setEventHandler {
            let slot = index % frames.count
            let now = ProcessInfo.processInfo.systemUptime
            host.counters.captured(idle: false)
            probe.pushed(slot: slot, at: now)
            host.pushFrame(frames[slot], timeStampNs: Int64(now * 1_000_000_000))
            index += 1
        }
        pump.resume()
        // Discard connection start-up so the percentiles describe the steady stream.
        let warmup = Double(ProcessInfo.processInfo.environment["POCKETDESK_BENCH_WARMUP"] ?? "") ?? 2
        try await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
        probe.reset()
        let steadyStart = hostReports.count, steadyPhoneStart = phoneReports.count
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        pump.cancel()
        let latency = probe.summary()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let steadyHost = Array(hostReports.dropFirst(steadyStart + 1))
        let steadyPhone = Array(phoneReports.dropFirst(steadyPhoneStart + 1))
        func median(_ values: [Double?]) -> String {
            let sorted = values.compactMap { $0 }.sorted()
            guard !sorted.isEmpty else { return "–" }
            return String(format: "%.1f", sorted[sorted.count / 2])
        }
        func total(_ values: [Int?]) -> Int { values.compactMap { $0 }.reduce(0, +) }
        let last = steadyHost.last ?? hostReports.last
        let lastPhone = steadyPhone.last ?? phoneReports.last
        XCTAssertTrue(phoneReports.contains { ($0.decodedFPS ?? 0) > 0 }, "receiver decoded the generated stream")
        if compatibleReceiver, let decodedWidth = lastPhone?.receivedWidth, let decodedHeight = lastPhone?.receivedHeight {
            let limit = H264FrameBudget.level(31)
            XCTAssertLessThanOrEqual(((decodedWidth + 15) / 16) * ((decodedHeight + 15) / 16) * 60, limit.macroblocksPerSecond)
        }
        print("""
        BENCH RECEIPT scene=\(scene) \(width)x\(height) \(Int(seconds))s tuning=[\(host.tuning.summary)]: \
        level=\(last?.h264ProfileLevel ?? "?") encoder=\(last?.encoderImplementation ?? "?") hw=\(last?.powerEfficientEncoder.map(String.init) ?? "?") \
        sent=\(last?.sentWidth ?? 0)x\(last?.sentHeight ?? 0) limit=\(last?.qualityLimitation ?? "?") | \
        pushedFPS=\(median(steadyHost.map { $0.pushedFPS })) encodedFPS=\(median(steadyHost.map { $0.encodedFPS })) \
        droppedPreEncode=\(total(steadyHost.map { $0.droppedBeforeEncode })) \
        encodeFullP50Ms=\(median(steadyHost.map { $0.encodeLatencyMs })) encodeFullP90Ms=\(median(steadyHost.map { $0.encodeLatencyP90Ms })) \
        encodeVTP90Ms=\(median(steadyHost.map { $0.encodeVTP90Ms })) inFlightMax=\(steadyHost.compactMap { $0.encodeInFlightMax }.max() ?? 0) \
        encodeMs=\(median(steadyHost.map { $0.encodeMs })) pacerMs=\(median(steadyHost.map { $0.pacerDelayMs })) \
        sentKbps=\(median(steadyHost.map { $0.sentKbps })) targetKbps=\(median(steadyHost.map { $0.targetKbps })) \
        bweKbps=\(median(steadyHost.map { $0.availableOutgoingKbps })) qp=\(median(steadyHost.map { $0.qpAverage })) | \
        decodedFPS=\(median(steadyPhone.map { $0.decodedFPS })) gapP90=\(median(steadyPhone.map { $0.renderGapP90Ms })) \
        gapMax=\(median(steadyPhone.map { $0.renderGapMaxMs })) assemblyMs=\(median(steadyPhone.map { $0.assemblyMs })) \
        jitterBufMs=\(median(steadyPhone.map { $0.jitterBufferMs })) jitterTargetMs=\(median(steadyPhone.map { $0.jitterBufferTargetMs })) \
        decodeMs=\(median(steadyPhone.map { $0.decodeMs })) dropped=\(lastPhone?.framesDropped ?? 0) | \
        pushToDecodedMs p50=\(latency.p50) p90=\(latency.p90) p99=\(latency.p99) n=\(latency.count) \
        distinctFPS=\(latency.distinctFPS) lumaPSNR=\(latency.psnr) psnrN=\(latency.psnrCount)
        """)
        if ProcessInfo.processInfo.environment["POCKETDESK_BENCH_VERBOSE"] == "1" {
            for report in hostReports + phoneReports { print(report.logLine) }
        }
    }

    private static func makeFrames(scene: String, width: Int, height: Int) throws -> [CVPixelBuffer] {
        let count = 1 << markerBits
        // "scroll": seamless continuous scrolling. "jump": 12 px steps whose loop wraps with a
        // 372 px jump, i.e. a near-full-screen change about twice a second (page flips, app switches).
        let step = scene == "jump" ? 12 : scrollStep
        let moving = scene == "scroll" || scene == "jump"
        let pageHeight = height + (moving ? count * step : 0)
        let page = ProcessInfo.processInfo.environment["POCKETDESK_BENCH_CONTENT"] == "noise"
            ? noisePage(width: width, height: pageHeight) : textPage(width: width, height: pageHeight)
        return try (0..<count).map { index in
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
                  let buffer else { throw XCTSkip("pixel buffer allocation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let offset = moving ? index * step : 0
            page.withUnsafeBufferPointer { source in
                for y in 0..<height {
                    memcpy(luma + y * lumaStride, source.baseAddress! + (y + offset) * width, width)
                }
            }
            if !moving {
                let windowX = (index * 37) % max(1, width - 640)
                let windowY = 200 + (index * 11) % max(1, height - 700)
                for y in windowY..<min(height, windowY + 480) {
                    let row = luma + y * lumaStride
                    for x in windowX..<min(width, windowX + 640) { row[x] = UInt8(truncatingIfNeeded: 60 + (x + y + index * 9) % 160) }
                }
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

    /// Worst case: incompressible glyph-like noise.
    private static func noisePage(width: Int, height: Int) -> [UInt8] {
        var page = [UInt8](repeating: 225, count: width * height)
        var seed: UInt32 = 0x1234_5678
        for y in 0..<height {
            let textLine = (y / 18) % 3 != 2 && (y % 18) > 3 && (y % 18) < 15
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let glyph = textLine && ((x / 9) % 7 != 6) && (seed >> 28) > 6
                page[y * width + x] = glyph ? 40 : 225
            }
        }
        return page
    }

    /// Representative: anti-aliased monospaced code at Retina scale (Menlo 24 px), video-range luma.
    private static func textPage(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height)
        let snippets = [
            "func configureNativeSender(quality: StreamQuality) -> RTCRtpParameters {",
            "    let parameters = sender.parameters // max 20_000_000 bps, start 8_000_000",
            "    for encoding in parameters.encodings { encoding.maxFramerate = 60 }",
            "    guard let track = connection?.receivers.first?.track as? RTCVideoTrack else { return nil }",
            "error: cannot convert value of type '[String: Any]' to expected argument type 'Int32'",
            "  0x00007ff8 in PeerMedia.publishStreamStatistics(_:) + 412 at PeerMedia.swift:233",
            "    XCTAssertEqual(report.jitterBufferMs ?? .nan, 3.7, accuracy: 0.1) // 2026-09-28",
            "}"
        ]
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setShouldAntialias(true)
            let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
            ]
            let lineHeight = 34.0
            var row = 0
            var y = Double(height) - lineHeight
            while y > 0 {
                let text = snippets[row % snippets.count]
                for column in stride(from: 0, to: width, by: 1400) {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                    context.textPosition = CGPoint(x: Double(column) + 24 + Double(row % 4) * 28, y: y)
                    CTLineDraw(line, context)
                }
                row += 1
                y -= lineHeight
            }
        }
        // Full-range gray to video-range luma, matching ScreenCaptureKit's 420v output.
        return pixels.map { UInt8(16 + (Int($0) * 219 + 127) / 255) }
    }

    fileprivate static func readMarker(luma: UnsafePointer<UInt8>, stride: Int, scale: Double) -> Int {
        var value = 0
        for bit in 0..<markerBits {
            let x = Int((Double(bit * markerBlock + markerBlock / 2) * scale).rounded(.down))
            let y = Int((Double(markerBlock / 2) * scale).rounded(.down))
            if luma[y * stride + x] > 128 { value |= 1 << bit }
        }
        return value
    }
}

private final class NoteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []
    func append(_ note: String) { lock.lock(); if notes.count < 400 { notes.append(note) }; lock.unlock() }
    func drain() -> [String] { lock.lock(); defer { lock.unlock() }; return notes }
}

/// Reads the frame-slot marker from each decoded frame to time push→decoded delivery, and
/// measures luma PSNR against the pushed source on a background queue.
private final class LatencyProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let sources: [CVPixelBuffer]
    private var pushedAt: [TimeInterval]
    private var lastSlot: Int?
    private var samples: [Double] = []
    private var distinct = 0
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var psnrValues: [Double] = []
    private var psnrBusy = false
    private var decodedCount = 0
    private let psnrQueue = DispatchQueue(label: "bench.psnr", qos: .utility)

    init(sources: [CVPixelBuffer]) {
        self.sources = sources
        pushedAt = [TimeInterval](repeating: 0, count: sources.count)
    }

    func pushed(slot: Int, at time: TimeInterval) {
        lock.lock(); pushedAt[slot] = time; lock.unlock()
    }

    func reset() {
        lock.lock(); samples.removeAll(); psnrValues.removeAll(); distinct = 0
        startedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let frame, let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer,
              CVPixelBufferGetPlaneCount(pixels) >= 1 else { return }
        let sourceWidth = CVPixelBufferGetWidth(sources[0])
        let scale = Double(CVPixelBufferGetWidth(pixels)) / Double(sourceWidth)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let slot = CVPixelBufferGetBaseAddressOfPlane(pixels, 0).map {
            StreamLoopbackBenchmarkTests.readMarker(luma: $0.assumingMemoryBound(to: UInt8.self),
                                                   stride: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), scale: scale)
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        guard let slot else { return }
        lock.lock(); defer { lock.unlock() }
        guard slot != lastSlot, pushedAt[slot] > 0 else { return }
        lastSlot = slot
        distinct += 1
        let latency = (now - pushedAt[slot]) * 1000
        if latency > 0, latency < 500 { samples.append(latency) }
        decodedCount += 1
        if decodedCount % 6 == 0, !psnrBusy, scale == 1 {
            psnrBusy = true
            let source = sources[slot]
            let dump = decodedCount == 240 ? ProcessInfo.processInfo.environment["POCKETDESK_BENCH_DUMP"] : nil
            psnrQueue.async { [weak self] in
                let value = Self.lumaPSNR(decoded: pixels, source: source)
                if let dump {
                    Self.writeLuma(pixels, to: "\(dump)-decoded.pgm")
                    Self.writeLuma(source, to: "\(dump)-source.pgm")
                }
                guard let self else { return }
                self.lock.lock(); if let value { self.psnrValues.append(value) }; self.psnrBusy = false; self.lock.unlock()
            }
        }
    }

    private static func writeLuma(_ buffer: CVPixelBuffer, to path: String) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var data = Data("P5\n\(width) \(height)\n255\n".utf8)
        for y in 0..<height { data.append(base + y * stride, count: width) }
        try? data.write(to: URL(fileURLWithPath: path))
        print("BENCH DUMP \(path) format=\(CVPixelBufferGetPixelFormatType(buffer))")
    }

    private static func lumaPSNR(decoded: CVPixelBuffer, source: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetWidth(decoded) == CVPixelBufferGetWidth(source),
              CVPixelBufferGetHeight(decoded) == CVPixelBufferGetHeight(source) else { return nil }
        CVPixelBufferLockBaseAddress(decoded, .readOnly); CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddressOfPlane(source, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0), strideB = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        // libwebrtc asks VideoToolbox for full-range output; the source is video range.
        let expand = CVPixelBufferGetPixelFormatType(decoded) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            && CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let expected: [Int] = (0..<256).map { value in
            expand ? max(0, min(255, Int((Double(value - 16) * 255 / 219).rounded()))) : value
        }
        var squared: UInt64 = 0, count: UInt64 = 0
        // Every fourth row and column below the marker strip is enough for a stable estimate.
        for y in stride(from: StreamLoopbackBenchmarkTests.markerBlock, to: height, by: 4) {
            let rowA = a + y * strideA, rowB = b + y * strideB
            for x in stride(from: 0, to: width, by: 4) {
                let diff = Int(rowA[x]) - expected[Int(rowB[x])]
                squared += UInt64(diff * diff); count += 1
            }
        }
        guard count > 0 else { return nil }
        let mse = Double(squared) / Double(count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    func summary() -> (p50: String, p90: String, p99: String, count: Int, distinctFPS: String, psnr: String, psnrCount: Int) {
        lock.lock(); defer { lock.unlock() }
        let sorted = samples.sorted()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let fps = elapsed > 0 ? String(format: "%.1f", Double(distinct) / elapsed) : "–"
        let psnrSorted = psnrValues.sorted()
        let psnr = psnrSorted.isEmpty ? "–" : String(format: "%.2f", psnrSorted[psnrSorted.count / 2])
        guard !sorted.isEmpty else { return ("–", "–", "–", 0, fps, psnr, psnrSorted.count) }
        func rank(_ fraction: Double) -> String { String(format: "%.1f", LatencyWindow.rank(sorted, fraction)) }
        return (rank(0.5), rank(0.9), rank(0.99), sorted.count, fps, psnr, psnrSorted.count)
    }
}
