import XCTest
import CoreImage
import CoreText
import CoreVideo
import ImageIO
import VideoToolbox
import WebRTC

/// Opt-in, same-content A/B of the owned encoder's QP ceiling. A fixed 2560×1664 text page (the bench
/// legibility chart plus code and prose) goes through `OwnedVTEncoder` as 60 still frames, 60 frames
/// scrolling down and 60 back up at 1,440 px/s, then 60 still frames. Bytes, drops and encode time
/// come from the encoder; four frames are decoded and scored with Vision CER and PSNR against the
/// source. Byte counts and CER do not need a quiet Mac; the encode-ms columns do.
///
///   FARSIDE_CRISP_BENCH=1 FARSIDE_CRISP_OUT=<dir> [FARSIDE_CRISP_TIMING=1] \
///     xcrun xctest -XCTest RemoteCoreTests.StillTextQPBenchTests <bundle>
final class StillTextQPBenchTests: XCTestCase {
    /// FARSIDE_CRISP_SCALE=1 runs the half-size ladder rung (1280×832, text at 1×).
    private static let scale: CGFloat = ProcessInfo.processInfo.environment["FARSIDE_CRISP_SCALE"] == "1" ? 1 : 2
    private static let width = Int(1280 * scale), height = Int(832 * scale)
    private static let points = CGSize(width: 1280, height: 832)
    private static let seed: UInt16 = 0x3a7
    private static let scrollStep = Int(12 * scale), scrollFrames = 60
    private static let documentHeight = height + scrollStep * scrollFrames
    private static let frameCount = 240
    private static let sampled = [0, 59, 180, 239]

    private struct Run {
        let codec: String, ceiling: Int, clarity: Bool, kbps: Int, nv12: Bool
        var label: String { "\(codec)-qp\(ceiling)\(clarity ? "" : "-noclarity")-\(kbps / 1000)M\(nv12 ? "-nv12" : "")" }
    }

    func testStillTextQPAB() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_CRISP_BENCH"] == "1", let out = environment["FARSIDE_CRISP_OUT"] else {
            throw XCTSkip("Set FARSIDE_CRISP_BENCH=1 and FARSIDE_CRISP_OUT=<dir> to run the still-text QP A/B.")
        }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try Self.renderDocument()
        let source = try XCTUnwrap(Self.frameImage(document, offset: 0))
        try Self.writePNG(Self.chartCrop(source), to: directory.appendingPathComponent("source-chart.png"))
        let ceiling = try LegibilityScore.score(image: Self.chartCrop(source), seed: Self.seed)
        var lines = ["{\"run\":\"source\",\"cer\":\(Self.json(ceiling.cerBySize))}"]

        var runs: [Run] = []
        for kbps in [25_000, 12_000, 5_000] {
            for codec in ["H264", "H265"] {
                runs.append(Run(codec: codec, ceiling: 30, clarity: false, kbps: kbps, nv12: false))
                runs.append(Run(codec: codec, ceiling: 26, clarity: true, kbps: kbps, nv12: false))
                if codec == "H265" { runs.append(Run(codec: codec, ceiling: 26, clarity: false, kbps: kbps, nv12: false)) }
            }
        }
        if environment["FARSIDE_CRISP_TIMING"] == "1" {
            for codec in ["H264", "H265"] { for qp in [30, 26] { runs.append(Run(codec: codec, ceiling: qp, clarity: qp == 26, kbps: 12_000, nv12: true)) } }
        }
        _ = try measure(runs[0], document: document, source: source) // warm the hardware encoder; discarded
        var decodedByRun: [String: [Int: CGImage]] = [:]
        for run in runs {
            let (line, decoded) = try measure(run, document: document, source: source)
            print("CRISP", line); lines.append(line); decodedByRun[run.label] = decoded
            for (index, image) in decoded { try Self.writePNG(Self.chartCrop(image), to: directory.appendingPathComponent("\(run.label)-f\(index).png")) }
        }
        for kbps in [25_000, 12_000, 5_000] {
            for codec in ["H264", "H265"] {
                let before = Run(codec: codec, ceiling: 30, clarity: false, kbps: kbps, nv12: false).label
                let after = Run(codec: codec, ceiling: 26, clarity: true, kbps: kbps, nv12: false).label
                for index in [0, 180, 239] {
                    guard let a = decodedByRun[before]?[index], let b = decodedByRun[after]?[index] else { continue }
                    try Self.writePNG(Self.sideBySide(Self.chartCrop(a), Self.chartCrop(b)),
                                      to: directory.appendingPathComponent("pair-\(codec)-\(kbps / 1000)M-f\(index)-qp30-vs-qp26.png"))
                }
            }
        }
        if environment["FARSIDE_CRISP_TIMING"] == "1" { lines.append(try refinementInspectTiming(document)) }
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("results.jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: - One run

    private func measure(_ run: Run, document: Document, source: CGImage) throws -> (String, [Int: CGImage]) {
        let configuration: any OwnedVideoConfiguration = run.codec == "H265"
            ? try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
            : try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"]))
        var ptsSeconds: TimeInterval = 100
        let clarity = run.clarity ? TextClarityContext(enabled: true, clock: { ptsSeconds }) : nil
        let counters = StreamCounters()
        let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, textClarity: clarity,
                                     inFlightLimit: { 1 }, maximumQPCeiling: { run.ceiling }, newestFrameWins: { false })
        defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = run.codec; settings.width = UInt16(Self.width); settings.height = UInt16(Self.height)
        settings.startBitrate = UInt32(run.kbps); settings.maxBitrate = UInt32(run.kbps); settings.maxFramerate = 60
        settings.qpMax = 51; settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "\(run.label) stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
        XCTAssertTrue(encoder.maximumQPApplied, run.label)

        let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        var outputs: [Int: (image: RTCEncodedImage, info: (any RTCCodecSpecificInfo)?, ms: Double)] = [:]
        var submittedAt: [Int: Double] = [:]
        encoder.setCallback { image, info in
            let index = Int((image.timeStamp - 90_000) / 1_500), now = CACurrentMediaTime() * 1000
            lock.lock(); outputs[index] = (image, info, now - (submittedAt[index] ?? now)); lock.unlock()
            signal.signal(); return true
        }
        let transfer = run.nv12 ? try Self.transferSession() : nil
        let pool = try Self.pool(format: run.nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
        let bgraPool = try Self.pool(format: kCVPixelFormatType_32BGRA)
        var timeouts = 0
        for index in 0..<Self.frameCount {
            let offset = Self.offset(index)
            if index == 0 || (index > 60 && index <= 180) { clarity?.contentChanged() }
            let bgra = try Self.frameBuffer(document, offset: offset, pool: bgraPool)
            var pixels = bgra
            if let transfer {
                pixels = try Self.buffer(from: pool)
                XCTAssertEqual(VTPixelTransferSessionTransferImage(transfer, from: bgra, to: pixels), noErr)
            }
            let ns = Int64(index) * 16_666_667 + 1_000_000_000
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: ns)
            frame.timeStamp = Int32(90_000 + index * 1_500)
            lock.lock(); submittedAt[index] = CACurrentMediaTime() * 1000; lock.unlock()
            XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: index == 0 ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : []), 0)
            if signal.wait(timeout: .now() + 0.25) == .timedOut { timeouts += 1 }
            ptsSeconds += 1.0 / 60
        }
        Thread.sleep(forTimeInterval: 0.3)
        let silentDrops = counters.drain(inputBufferedBytes: nil).encoderSilentDrops ?? 0
        lock.lock(); let encoded = outputs; lock.unlock()

        let bytes = (0..<Self.frameCount).map { encoded[$0]?.image.buffer.count ?? 0 }
        let keyBytes = bytes[0]
        func window(_ range: Range<Int>) -> Int { range.map { bytes[$0] }.reduce(0, +) }
        let peakWindow = (0...(Self.frameCount - 60)).map { window($0..<($0 + 60)) }.max() ?? 0
        func ms(_ range: Range<Int>) -> [Double] { range.compactMap { encoded[$0]?.ms }.sorted() }
        func pct(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        let scrollMs = ms(60..<180), stillMs = ms(181..<240)
        let keyIndices = (0..<Self.frameCount).filter { encoded[$0]?.image.frameType == .videoFrameKey }

        let decoded = try decode(run, encoded: encoded.mapValues { ($0.image, $0.info) })
        var quality: [String] = []
        for index in Self.sampled {
            guard let image = decoded[index] else { quality.append("\"f\(index)\":null"); continue }
            let expected = try XCTUnwrap(Self.frameImage(document, offset: Self.offset(index)))
            let psnr = Self.psnr(Self.chartCrop(image), Self.chartCrop(expected))
            var cer: [String: Double] = [:]
            if Self.offset(index) == 0 { cer = try LegibilityScore.score(image: Self.chartCrop(image), seed: Self.seed).cerBySize }
            quality.append("\"f\(index)\":{\"psnr\":\(String(format: "%.2f", psnr)),\"cer\":\(Self.json(cer))}")
        }
        let line = "{\"run\":\"\(run.label)\",\"kbps\":\(run.kbps),\"qpCeiling\":\(run.ceiling),\"clarity\":\(run.clarity),\"input\":\"\(run.nv12 ? "nv12" : "bgra")\""
            + ",\"keyBytes\":\(keyBytes),\"keyLinkMs\":\(String(format: "%.1f", Double(keyBytes) * 8 / Double(run.kbps)))"
            + ",\"keyFrames\":\(keyIndices.count),\"keyAt\":\(keyIndices),\"keyBytesAll\":\(keyIndices.map { bytes[$0] }),\"still1sBytes\":\(window(0..<60)),\"stillDeltaMeanBytes\":\(window(1..<60) / 59)"
            + ",\"scrollMeanBytes\":\(window(60..<180) / 120),\"scrollMaxBytes\":\(bytes[60..<180].max() ?? 0)"
            + ",\"settle1sBytes\":\(window(180..<240)),\"peak1sKbit\":\(peakWindow * 8 / 1000),\"peak1sOverTarget\":\(String(format: "%.2f", Double(peakWindow) * 8 / 1000 / Double(run.kbps)))"
            + ",\"emitted\":\(encoded.count),\"silentDrops\":\(silentDrops),\"timeouts\":\(timeouts)"
            + ",\"encodeMs\":{\"key\":\(String(format: "%.2f", encoded[0]?.ms ?? -1)),\"scrollP50\":\(String(format: "%.2f", pct(scrollMs, 0.5))),\"scrollP95\":\(String(format: "%.2f", pct(scrollMs, 0.95))),\"stillP50\":\(String(format: "%.2f", pct(stillMs, 0.5)))}"
            + ",\"quality\":{\(quality.joined(separator: ","))}}"
        return (line, decoded)
    }

    private func decode(_ run: Run, encoded: [Int: (RTCEncodedImage, (any RTCCodecSpecificInfo)?)]) throws -> [Int: CGImage] {
        let decoder: any RTCVideoDecoder = run.codec == "H265"
            ? OwnedHEVCDecoder(configuration: try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters)))
            : RTCVideoDecoderH264()
        defer { _ = decoder.release() }
        let lock = NSLock(), signal = DispatchSemaphore(value: 0), context = CIContext()
        var images: [Int: CGImage] = [:]
        decoder.setCallback { frame in
            let index = Int((UInt32(bitPattern: frame.timeStamp) - 90_000) / 1_500)
            if Self.sampled.contains(index), let buffer = frame.buffer as? RTCCVPixelBuffer {
                let image = CIImage(cvPixelBuffer: buffer.pixelBuffer)
                if let cg = context.createCGImage(image, from: image.extent) { lock.lock(); images[index] = cg; lock.unlock() }
            }
            signal.signal()
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        for index in encoded.keys.sorted() {
            guard let entry = encoded[index] else { continue }
            XCTAssertEqual(decoder.decode(entry.0, missingFrames: false, codecSpecificInfo: entry.1, renderTimeMs: 0), 0, "\(run.label) frame \(index)")
            _ = signal.wait(timeout: .now() + 1)
        }
        lock.lock(); defer { lock.unlock() }; return images
    }

    /// The per-frame refinement check (ROI hash and opacity scan) that runs on the encoder queue
    /// whenever still-text refinement is negotiated.
    private func refinementInspectTiming(_ document: Document) throws -> String {
        let producer = VideoRefinementProducer(), pool = try Self.pool(format: kCVPixelFormatType_32BGRA)
        let tag = VideoFrameTag(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32), geometryEpoch: 1, scopeEpoch: 1, ltrToken: nil)
        var samples: [Double] = []
        for index in 0..<120 {
            let buffer = try Self.frameBuffer(document, offset: Self.offset(index + 60), pool: pool)
            let start = CACurrentMediaTime()
            _ = producer.inspect(buffer, tag: tag, at: Double(index) / 60) { _ in }
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        producer.reset(terminal: true)
        samples.sort()
        return "{\"run\":\"refinement-inspect\",\"p50Ms\":\(String(format: "%.3f", samples[60])),\"p95Ms\":\(String(format: "%.3f", samples[114]))}"
    }

    // MARK: - Content

    private struct Document { let data: Data; let bytesPerRow: Int }

    private static func offset(_ index: Int) -> Int {
        switch index {
        case 61...120: return (index - 60) * scrollStep
        case 121...180: return (180 - index) * scrollStep
        default: return 0
        }
    }

    private static func renderDocument() throws -> Document {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * documentHeight)
        try data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: documentHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw XCTSkip("no BGRA context") }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: documentHeight))
            context.translateBy(x: 0, y: CGFloat(documentHeight))
            context.scaleBy(x: scale, y: -scale)
            let layout = LegibilityChart.layout(displayPointSize: points)
            LegibilityChartRenderer.draw(cells: LegibilityChart.cells(seed: seed), layout: layout, in: context)
            var state: UInt32 = 0x9E37_79B9
            func word() -> String {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                let pool = ["let", "frame", "encoder", "guard", "return", "session", "bitrate", "pixels", "if", "else", "self", "queue",
                            "width", "height", "func", "var", "true", "nil", "count", "map", "the", "Mac", "phone", "text", "crisp"]
                return pool[Int(state % UInt32(pool.count))]
            }
            func line(_ x: CGFloat, _ y: CGFloat, _ font: CTFont, _ words: Int, _ colour: CGColor) {
                let text = (0..<words).map { _ in word() }.joined(separator: " ")
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                 NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour]
                context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1); context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
                context.restoreGState()
            }
            let mono = CTFontCreateWithName("Menlo" as CFString, 11, nil)
            let prose = CTFontCreateUIFontForLanguage(.system, 13, nil)!
            let black = CGColor(gray: 0, alpha: 1), blue = CGColor(srgbRed: 0, green: 0.35, blue: 0.85, alpha: 1)
            var y = layout.frame.maxY + 24
            while y < CGFloat(documentHeight) / scale - 8 { line(40, y, mono, 9, Int(y) % 5 == 0 ? blue : black); y += 15 }
            y = layout.frame.minY + 10
            while y < CGFloat(documentHeight) / scale - 8 { line(layout.frame.maxX + 24, y, prose, 5, black); y += 18 }
        }
        return Document(data: data, bytesPerRow: bytesPerRow)
    }

    private static func pool(format: OSType) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw XCTSkip("no pixel pool") }
        return pool
    }
    private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw XCTSkip("pool exhausted") }
        return buffer
    }
    private static func frameBuffer(_ document: Document, offset: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        let buffer = try buffer(from: pool)
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!
        document.data.withUnsafeBytes { raw in
            for row in 0..<height { memcpy(base.advanced(by: row * stride), raw.baseAddress!.advanced(by: (row + offset) * document.bytesPerRow), width * 4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }
    private static func transferSession() throws -> VTPixelTransferSession {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { throw XCTSkip("no transfer session") }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        return session
    }
    private static func frameImage(_ document: Document, offset: Int) -> CGImage? {
        let slice = document.data.subdata(in: (offset * document.bytesPerRow)..<((offset + height) * document.bytesPerRow))
        guard let provider = CGDataProvider(data: slice as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: document.bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Scoring and output

    private static func chartCrop(_ image: CGImage) -> CGImage {
        let rect = LegibilityChart.layout(displayPointSize: points).frame.insetBy(dx: -8, dy: -8)
        return image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral) ?? image
    }
    private static func gray(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
    private static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        let x = gray(a), y = gray(b)
        guard x.count == y.count, !x.isEmpty else { return 0 }
        let mse = zip(x, y).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(x.count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
    private static func sideBySide(_ a: CGImage, _ b: CGImage) -> CGImage {
        let gap = 24, width = a.width + b.width + gap, height = max(a.height, b.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(a, in: CGRect(x: 0, y: height - a.height, width: a.width, height: a.height))
        context.draw(b, in: CGRect(x: a.width + gap, y: height - b.height, width: b.width, height: b.height))
        return context.makeImage()!
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw XCTSkip("no PNG writer") }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private static func json(_ values: [String: Double]) -> String {
        "{" + values.keys.sorted().map { "\"\($0)\":\(values[$0]!)" }.joined(separator: ",") + "}"
    }
}
