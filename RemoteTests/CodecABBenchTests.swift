import XCTest
import Accelerate
import CryptoKit
import CoreImage
import CoreText
import CoreVideo
import ImageIO
import VideoToolbox
import WebRTC

/// Offline, opt-in encode/decode comparison. This exercises the owned hardware encoder and the
/// shipped H.264/HEVC decoders, but deliberately excludes capture, WebRTC transport, phone display,
/// feedback/LTR negotiation and physical-device performance.
///
/// FARSIDE_CODEC_BENCH=1 FARSIDE_CODEC_OUT=<dir> FARSIDE_CODEC_MODE=quality|timing \
///   [FARSIDE_CODEC_FRAMES=240] [FARSIDE_CODEC_CASE=substring] xcrun xctest \
///   -XCTest RemoteCoreTests.CodecABBenchTests/testCodecAB <bundle>
/// Timing additionally requires testing/QUIET-GRANTED-b7-codec. Frames are generated before each
/// timed run; callbacks only stamp/hand off frames. Source and decoded pixels are never scored in
/// timing mode. The run order reverses on repeat 2 to reduce thermal/order bias.
final class CodecABBenchTests: XCTestCase {
    private let fps = 60
    private let seed: UInt32 = 0x7E41_0B7A
    private let display = DisplayGeometry(size: CGSize(width: 1280, height: 828), pointPixelScale: 2)
    private let whole = CapturePixelDimensions(width: 2560, height: 1656)
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    private struct Geometry {
        let name: String
        let region: CaptureRegion
        var width: Int { region.outputWidth }
        var height: Int { region.outputHeight }
    }
    private struct Rate { let name: String; let kbps: Int }
    private struct Case { let geometry: Geometry; let rate: Rate; let codec: String
        var label: String { "\(geometry.name)-\(codec)-\(rate.name)" }
    }
    private struct EncodeReceipt {
        let image: RTCEncodedImage
        let info: (any RTCCodecSpecificInfo)?
        let callbackMs: Double
    }
    private struct DecodeReceipt { let frame: RTCVideoFrame; let callbackMs: Double }
    private struct FrameSource { let pixels: CVPixelBuffer; let hash: String; let phase: String }
    private struct LumaRange {
        let scale: Float
        let offset: Float
        let name: String
    }
    private final class VirtualClock {
        private let lock = NSLock()
        private var value: Double = 0
        func set(_ next: Double) { lock.lock(); value = next; lock.unlock() }
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class Mailbox<T> {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var item: T?
        func put(_ value: T) { lock.lock(); item = value; lock.unlock(); semaphore.signal() }
        func take(timeout: Double) -> T? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            let value = item; item = nil; return value
        }
    }
    private final class JSONLines {
        let file: FileHandle
        init(_ url: URL) throws {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try FileHandle(forWritingTo: url)
        }
        func write(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            try file.write(contentsOf: data + Data([10]))
        }
        func close() { try? file.close() }
    }

    func testCodecAB() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FARSIDE_CODEC_BENCH"] == "1", let out = env["FARSIDE_CODEC_OUT"], !out.isEmpty else {
            throw XCTSkip("Set FARSIDE_CODEC_BENCH=1 and FARSIDE_CODEC_OUT=<dir> for the offline codec A/B.")
        }
        let mode = env["FARSIDE_CODEC_MODE"] ?? "quality"
        guard mode == "quality" || mode == "timing" else { throw XCTSkip("FARSIDE_CODEC_MODE must be quality or timing") }
        if mode == "timing" {
            let quiet = URL(fileURLWithPath: "/Users/roshansilva/Documents/Codex/2026-10-01/testing/QUIET-GRANTED-b7-codec")
            guard FileManager.default.fileExists(atPath: quiet.path) else {
                throw XCTSkip("Timing needs QUIET-GRANTED-b7-codec; use quality mode for an ordinary offline run.")
            }
        }
        let count = max(12, min(360, Int(env["FARSIDE_CODEC_FRAMES"] ?? "") ?? 240))
        if mode == "timing", count > 240 { throw XCTSkip("Timing corpus is capped at 240 full-size NV12 frames (about 1.5 GB).") }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = try JSONLines(directory.appendingPathComponent("codec-\(mode).jsonl"))
        defer { lines.close() }
        let geometries = try geometryCases()
        let tuning = StreamTuning.current
        let encoderOptions = OwnedEncoderOptions(tuning)
        XCTAssertEqual(tuning.encoderMaximumQP, StreamTuning.tuned.encoderMaximumQP)
        XCTAssertEqual(tuning.encoderMaxInFlight, StreamTuning.tuned.encoderMaxInFlight)
        XCTAssertTrue(NewestFrameWinsSwitch.isOn)
        XCTAssertEqual(encoderOptions, OwnedEncoderOptions(StreamTuning.tuned))
        let rates = [
            Rate(name: "relay-seed", kbps: StreamQuality.sharp.startBitrateBps(for: .relay) / 1000),
            Rate(name: "p2p-seed", kbps: StreamQuality.sharp.startBitrateBps(for: .p2p) / 1000),
            Rate(name: "responsive-lan-floor", kbps: (LANBitrateFloor.bps(startBitrateBps: StreamQuality.balanced.startBitrateBps(for: .lan)) ?? StreamQuality.balanced.startBitrateBps) / 1000),
            Rate(name: "sharp-lan-floor", kbps: (LANBitrateFloor.bps(startBitrateBps: StreamQuality.sharp.startBitrateBps(for: .lan)) ?? StreamQuality.sharp.startBitrateBps) / 1000),
            Rate(name: "responsive-ceiling", kbps: StreamQuality.balanced.maximumBitrateBps / 1000),
            Rate(name: "sharp-ceiling", kbps: StreamQuality.sharp.maximumBitrateBps / 1000)
        ]
        let all = geometries.flatMap { geometry in rates.flatMap { rate in ["H264", "H265"].map { Case(geometry: geometry, rate: rate, codec: $0) } } }
        let filter = env["FARSIDE_CODEC_CASE"] ?? ""
        let selected = all.filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) }
        XCTAssertFalse(selected.isEmpty, "FARSIDE_CODEC_CASE matched no case")
        try lines.write(["kind": "meta", "mode": mode, "frames": count, "fps": fps, "seed": seed,
                         "filter": filter, "caseLabels": selected.map(\.label), "repeatCount": mode == "timing" ? 2 : 1,
                         "input": "NV12 video range; sRGB BGRA transferred with BT.601 matrix",
                         "feedback": "absent: no live VideoFeedbackContext/LTR or network adaptation",
                         "h264ProfileAssumption": "High 5.2 (640034) observed previously; actual live SDP remains route/device dependent",
                         "submissionPacing": "serial callback-gated with 60 fps media timestamps; not 60 Hz wall cadence",
                         "encoderMaximumQP": tuning.encoderMaximumQP,
                         "encoderMaxInFlight": tuning.encoderMaxInFlight as Any? ?? NSNull(),
                         "newestFrameWins": NewestFrameWinsSwitch.isOn,
                         "ownedOptions": ["realTime": encoderOptions.realTime,
                                          "minimumExpectedFPS": encoderOptions.minimumExpectedFPS,
                                          "periodicKeyFrames": encoderOptions.periodicKeyFrames,
                                          "prioritizeSpeed": encoderOptions.prioritizeSpeed,
                                          "hevcLowLatency": encoderOptions.hevcLowLatency],
                         "lanFloorOverrideKbps": LANBitrateFloor.override as Any? ?? NSNull(),
                         "measurement": mode == "quality" ? "all decoded frames: NV12 Y PSNR and sampled 8x8 text ROI SSIM, stride 32" : "encode/decode submit-to-outward-callback ms; no pixel scoring"]) 
        let repeats = mode == "timing" ? 2 : 1
        for repeatIndex in 0..<repeats {
            let order = repeatIndex.isMultiple(of: 2) ? selected : Array(selected.reversed())
            for item in order {
                try autoreleasepool {
                    try run(item, repeatIndex: repeatIndex, count: count, timing: mode == "timing", directory: directory, lines: lines)
                }
            }
        }
    }

    private func geometryCases() throws -> [Geometry] {
        let full = ViewportCapturePolicy.wholeDisplay(display, output: whole)
        func crop(_ name: String, phone: CGSize, zoom: Double) throws -> Geometry {
            let width = Double(phone.width) / zoom, height = Double(phone.height) / zoom
            let viewport = ViewportRegion(epoch: 1, x: (1280 - width) / 2, y: (828 - height) / 2,
                                          width: width, height: height, pixelWidth: Int(phone.width), pixelHeight: Int(phone.height), zoom: zoom)
            let region = ViewportCapturePolicy.region(for: viewport, display: display, output: whole,
                                                      tuning: .tuned, previous: nil, phoneNative: true)
            XCTAssertFalse(region.isWholeDisplay, "\(name) must exercise a real zoom crop")
            XCTAssertEqual(region.outputWidth % 16, 0)
            XCTAssertEqual(region.outputHeight % 16, 0)
            return Geometry(name: name, region: region)
        }
        return [Geometry(name: "full", region: full),
                try crop("portrait-zoom2", phone: CGSize(width: 1206, height: 2622), zoom: 2),
                try crop("landscape-zoom3", phone: CGSize(width: 2622, height: 1206), zoom: 3)]
    }

    private func run(_ item: Case, repeatIndex: Int, count: Int, timing: Bool, directory: URL, lines: JSONLines) throws {
        let geometry = item.geometry
        let configuration: any OwnedVideoConfiguration = item.codec == "H264"
            ? try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"]))
            : try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        XCTAssertTrue(configuration.fits(width: geometry.width, height: geometry.height, fps: fps), item.label)
        let clock = VirtualClock()
        let clarity = TextClarityContext(enabled: true, clock: { clock.read() })
        let counters = StreamCounters()
        // Deliberately use OwnedVTEncoder's default QP, in-flight, newest-frame and options closures.
        // There is no feedback object in this isolated encode/decode comparison.
        let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, textClarity: clarity)
        defer { _ = encoder.release() }
        let decoder: any RTCVideoDecoder = item.codec == "H264" ? RTCVideoDecoderH264() : OwnedHEVCDecoder(configuration: try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters)))
        defer { _ = decoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = item.codec; settings.width = UInt16(geometry.width); settings.height = UInt16(geometry.height)
        settings.startBitrate = UInt32(item.rate.kbps); settings.maxBitrate = UInt32(item.rate.kbps)
        settings.maxFramerate = UInt32(fps); settings.qpMax = 51; settings.mode = .screensharing
        let started = encoder.startEncode(with: settings, numberOfCores: 1)
        XCTAssertEqual(started, 0, "\(item.label) stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
        guard started == 0 else { return }
        XCTAssertNotEqual(encoder.hardwareReported, false)
        XCTAssertTrue(encoder.maximumQPApplied, "\(item.label) maximum QP property must be active")
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        let encodeBox = Mailbox<EncodeReceipt>(), decodeBox = Mailbox<DecodeReceipt>()
        encoder.setCallback { image, info in
            encodeBox.put(EncodeReceipt(image: image, info: info, callbackMs: Self.nowMs()))
            return true
        }
        decoder.setCallback { frame in decodeBox.put(DecodeReceipt(frame: frame, callbackMs: Self.nowMs())) }

        let bgraPool = try pool(width: geometry.width, height: geometry.height, format: kCVPixelFormatType_32BGRA)
        let nv12Pool = try pool(width: geometry.width, height: geometry.height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let transfer = try transferSession()
        let prepared: [FrameSource] = timing ? try (0..<count).map { index in
            try autoreleasepool { try source(for: index, count: count, geometry: geometry,
                                              bgraPool: bgraPool, nv12Pool: nv12Pool, transfer: transfer) }
        } : []
        if timing { Thread.sleep(forTimeInterval: 2) } // Source synthesis is outside the timed run.
        if timing, let first = prepared.first {
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: first.pixels), rotation: ._0, timeStampNs: 500_000_000)
            frame.timeStamp = 45_000
            guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]) == 0,
                  let encoded = encodeBox.take(timeout: 0.5),
                  decoder.decode(encoded.image, missingFrames: false, codecSpecificInfo: encoded.info, renderTimeMs: 0) == 0,
                  decodeBox.take(timeout: 0.5) != nil else {
                XCTFail("\(item.label) warmup did not encode and decode")
                return
            }
        }
        clock.set(0)
        clarity.contentChanged()
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        var encodeTimes: [Double] = [], decodeTimes: [Double] = [], sizes: [Int] = [], keys: [(Int, Int)] = []
        var qualityPSNR: [Double] = [], qualitySSIM: [Double] = []
        var encodeMissing = 0, decodeMissing = 0, wrongTimestamp = 0, wrongDimensions = 0
        var lastDecoded: CVPixelBuffer?
        var decodedFormats = Set<String>()
        var timeline = [Int](repeating: 0, count: count)
        var phaseBytes: [String: [Int]] = [:], phasePSNR: [String: [Double]] = [:], phaseSSIM: [String: [Double]] = [:]
        var phaseEncode: [String: [Double]] = [:], phaseDecode: [String: [Double]] = [:]
        var phaseClarity: [String: Int] = [:]
        let runName = "\(item.label)-r\(repeatIndex + 1)"
        let sampleIndices: Set<Int> = [0, count / 3, 2 * count / 3, count - 1]
        for index in 0..<count {
            let source = timing ? prepared[index] : try autoreleasepool {
                try source(for: index, count: count, geometry: geometry,
                           bgraPool: bgraPool, nv12Pool: nv12Pool, transfer: transfer)
            }
            let phase = timing ? source.phase : phaseName(index, count: count)
            let virtualSeconds = Double(index) / Double(fps)
            clock.set(virtualSeconds)
            if phase != "still" { clarity.contentChanged() }
            let stamp = Int32(90_000 + index * (90_000 / fps))
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: source.pixels), rotation: ._0,
                                      timeStampNs: Int64(1_000_000_000 + index * (1_000_000_000 / fps)))
            frame.timeStamp = stamp
            let encodedSubmit = Self.nowMs()
            let encodeStatus = encoder.encode(frame, codecSpecificInfo: nil,
                                              frameTypes: index == 0 ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : [])
            XCTAssertEqual(encodeStatus, 0, "\(runName) encode frame \(index)")
            guard let encoded = encodeBox.take(timeout: 0.25) else {
                encodeMissing += 1
                let held = !timing && lastDecoded != nil ? try Self.psnrY(source.pixels, lastDecoded!) : nil
                try lines.write(["kind": "frame", "run": runName, "index": index, "phase": phase,
                                 "sourceHash": source.hash, "encodeMissing": true, "decodeMissing": true,
                                 "heldPSNRY": held.map(Self.round) as Any? ?? NSNull()])
                continue
            }
            if encoded.image.timeStamp != UInt32(bitPattern: stamp) { wrongTimestamp += 1 }
            let encodeMs = encoded.callbackMs - encodedSubmit
            let bytes = encoded.image.buffer.count, isKey = encoded.image.frameType == .videoFrameKey
            let clarityActive = encoder.textClarityActive
            if clarityActive { phaseClarity[phase, default: 0] += 1 }
            encodeTimes.append(encodeMs); sizes.append(bytes)
            timeline[index] = bytes
            phaseBytes[phase, default: []].append(bytes)
            phaseEncode[phase, default: []].append(encodeMs)
            if isKey { keys.append((index, bytes)) }
            let decodedSubmit = Self.nowMs()
            let decodeStatus = decoder.decode(encoded.image, missingFrames: encodeMissing > 0,
                                              codecSpecificInfo: encoded.info, renderTimeMs: 0)
            XCTAssertEqual(decodeStatus, 0, "\(runName) decode frame \(index)")
            guard let decoded = decodeBox.take(timeout: 0.25) else {
                decodeMissing += 1
                let held = !timing && lastDecoded != nil ? try Self.psnrY(source.pixels, lastDecoded!) : nil
                try lines.write(["kind": "frame", "run": runName, "index": index, "phase": phase,
                                 "sourceHash": source.hash, "bytes": bytes, "key": isKey,
                                 "encodeMs": timing ? Self.round(encodeMs) as Any : NSNull(), "decodeMissing": true,
                                 "heldPSNRY": held.map(Self.round) as Any? ?? NSNull()])
                continue
            }
            if decoded.frame.timeStamp != stamp { wrongTimestamp += 1 }
            guard let decodedPixels = (decoded.frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
                wrongDimensions += 1; continue
            }
            if CVPixelBufferGetWidth(decodedPixels) != geometry.width || CVPixelBufferGetHeight(decodedPixels) != geometry.height {
                wrongDimensions += 1
            }
            lastDecoded = decodedPixels
            let decodeMs = decoded.callbackMs - decodedSubmit
            decodeTimes.append(decodeMs)
            let decodedFormat = try Self.lumaRange(decodedPixels).name
            decodedFormats.insert(decodedFormat)
            phaseDecode[phase, default: []].append(decodeMs)
            var record: [String: Any] = ["kind": "frame", "run": runName, "index": index, "phase": phase,
                                         "sourceHash": source.hash, "rtp": UInt32(bitPattern: stamp),
                                         "bytes": bytes, "key": isKey, "encodeMissing": false, "decodeMissing": false,
                                         "sourceFormat": try Self.lumaRange(source.pixels).name, "decodedFormat": decodedFormat,
                                         "textClarityActive": clarityActive,
                                         "effectiveMaxQP": encoder.maximumQPApplied ? (clarityActive ? TextClarityPolicy.stillFrameQP(hevc: item.codec == "H265", sessionBound: StreamTuning.current.encoderMaximumQP) : StreamTuning.current.encoderMaximumQP) as Any : NSNull()]
            if timing {
                record["encodeMs"] = Self.round(encodeMs); record["decodeMs"] = Self.round(decodeMs)
                record["psnrY"] = NSNull(); record["textSSIM"] = NSNull()
            } else {
                let psnr = try Self.psnrY(source.pixels, decodedPixels)
                let roi = textROI(geometry)
                let ssim = try Self.sampledSSIMY(source.pixels, decodedPixels, roi: roi)
                qualityPSNR.append(psnr); qualitySSIM.append(ssim)
                phasePSNR[phase, default: []].append(psnr)
                phaseSSIM[phase, default: []].append(ssim)
                record["psnrY"] = Self.round(psnr); record["textSSIM"] = Self.round(ssim)
                record["encodeMs"] = NSNull(); record["decodeMs"] = NSNull()
                if sampleIndices.contains(index) {
                    let crop = CGRect(x: roi.minX, y: roi.minY, width: min(512, roi.width), height: min(320, roi.height))
                    try writePNG(source.pixels, rect: crop, to: directory.appendingPathComponent("\(runName)-f\(index)-source.png"))
                    try writePNG(decodedPixels, rect: crop, to: directory.appendingPathComponent("\(runName)-f\(index)-decoded.png"))
                }
            }
            try lines.write(record)
        }
        let gate = encoder.inFlightCounts
        let thermalAfter = ProcessInfo.processInfo.thermalState.rawValue
        let silentDrops = counters.drain(inputBufferedBytes: nil).encoderSilentDrops ?? 0
        let burst = timeline.indices.map { index in
            timeline[max(0, index - fps + 1)...index].reduce(0, +)
        }.max() ?? 0
        for phase in ["still", "scroll-reverse", "video", "mixed"] {
            let bytes = phaseBytes[phase] ?? []
            try lines.write(["kind": "phase", "run": runName, "phase": phase, "emitted": bytes.count,
                             "textClarityFrames": phaseClarity[phase] ?? 0,
                             "meanBytesPerFrame": bytes.isEmpty ? NSNull() : Double(bytes.reduce(0, +)) / Double(bytes.count) as Any,
                             "encodeP50Ms": timing ? Self.percentile(phaseEncode[phase] ?? [], 0.5) : NSNull(),
                             "encodeP90Ms": timing ? Self.percentile(phaseEncode[phase] ?? [], 0.9) : NSNull(),
                             "decodeP50Ms": timing ? Self.percentile(phaseDecode[phase] ?? [], 0.5) : NSNull(),
                             "decodeP90Ms": timing ? Self.percentile(phaseDecode[phase] ?? [], 0.9) : NSNull(),
                             "psnrYP50": timing ? NSNull() : Self.percentile(phasePSNR[phase] ?? [], 0.5),
                             "textSSIMP50": timing ? NSNull() : Self.percentile(phaseSSIM[phase] ?? [], 0.5)])
        }
        try lines.write(["kind": "aggregate", "run": runName, "codec": item.codec, "profile": item.codec == "H264" ? "High level 5.2; packetization 1 (historical negotiated default assumption)" : "HEVC Main1 level 5.1 high tier",
                         "geometry": geometry.name, "width": geometry.width, "height": geometry.height,
                         "region": ["x": geometry.region.x, "y": geometry.region.y, "width": geometry.region.width, "height": geometry.region.height],
                         "kbps": item.rate.kbps, "ratePoint": item.rate.name, "frames": count,
                         "thermalBefore": thermalBefore, "thermalAfter": thermalAfter,
                         "emitted": sizes.count, "encodeMissing": encodeMissing, "decodeMissing": decodeMissing,
                         "wrongTimestamp": wrongTimestamp, "wrongDimensions": wrongDimensions,
                         "gateDropped": gate.droppedByLimit, "vtSilentDrops": silentDrops, "gateRetired": gate.retiredByTimeout,
                         "sourceFormat": "420v", "decodedFormats": decodedFormats.sorted(),
                         "maximumQPBound": encoder.maximumQPApplied ? StreamTuning.current.encoderMaximumQP as Any : NSNull(),
                         "keyFrames": keys.map { ["index": $0.0, "bytes": $0.1] }, "peakOneSecondBytes": burst,
                         "totalBytes": sizes.reduce(0, +), "meanBytesPerFrame": sizes.isEmpty ? NSNull() : Double(sizes.reduce(0, +)) / Double(sizes.count) as Any,
                         "encodeP50Ms": timing ? Self.percentile(encodeTimes, 0.5) as Any : NSNull(),
                         "encodeP90Ms": timing ? Self.percentile(encodeTimes, 0.9) as Any : NSNull(),
                         "decodeP50Ms": timing ? Self.percentile(decodeTimes, 0.5) as Any : NSNull(),
                         "decodeP90Ms": timing ? Self.percentile(decodeTimes, 0.9) as Any : NSNull(),
                         "psnrYP50": timing ? NSNull() : Self.percentile(qualityPSNR, 0.5) as Any,
                         "textSSIMP50": timing ? NSNull() : Self.percentile(qualitySSIM, 0.5) as Any,
                         "hardwareReported": encoder.hardwareReported as Any? ?? NSNull(),
                         "maximumQPApplied": encoder.maximumQPApplied, "textClarityAvailable": encoder.textClarityAvailable,
                         "optionsEvidence": encoder.optionsEvidence ?? "", "feedback": "absent"])
        XCTAssertLessThanOrEqual(encodeMissing, gate.droppedByLimit + silentDrops,
                                 "\(runName) missing encoder callbacks exceed reported drops")
        XCTAssertEqual(decodeMissing, 0, "\(runName) decoder callback timed out")
        XCTAssertEqual(wrongTimestamp, 0, "\(runName) RTP timestamp mismatch")
        XCTAssertEqual(wrongDimensions, 0, "\(runName) decoded dimensions mismatch")
    }

    private func phaseName(_ index: Int, count: Int) -> String {
        if index < count / 4 { return "still" }
        if index < count / 2 { return "scroll-reverse" }
        if index < count * 3 / 4 { return "video" }
        return "mixed"
    }

    /// Source editor area in desktop pixels, intersected with the sourceRect and mapped exactly to
    /// the encoded output. The video tile begins at x=1706, beyond this text-only ROI.
    private func textROI(_ geometry: Geometry) -> CGRect {
        let source = geometry.region.rect.applying(CGAffineTransform(scaleX: 2, y: 2))
        let editor = CGRect(x: 0, y: 54, width: 1600, height: 1550)
        let visible = source.intersection(editor)
        let sx = CGFloat(geometry.width) / source.width, sy = CGFloat(geometry.height) / source.height
        return CGRect(x: (visible.minX - source.minX) * sx, y: (visible.minY - source.minY) * sy,
                      width: visible.width * sx, height: visible.height * sy).integral
    }

    private func source(for index: Int, count: Int, geometry: Geometry, bgraPool: CVPixelBufferPool,
                        nv12Pool: CVPixelBufferPool, transfer: VTPixelTransferSession) throws -> FrameSource {
        let bgra = try buffer(from: bgraPool), nv12 = try buffer(from: nv12Pool)
        let width = 2560, height = 1656
        CVPixelBufferLockBaseAddress(bgra, [])
        guard let base = CVPixelBufferGetBaseAddress(bgra), let context = CGContext(data: base, width: geometry.width, height: geometry.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(bgra, [])
            throw NSError(domain: "CodecAB", code: 1)
        }
        let phase = phaseName(index, count: count)
        let quarter = max(1, count / 4)
        let scrollIndex = phase == "scroll-reverse" ? min(index - quarter, 2 * quarter - index)
            : phase == "mixed" ? index - 3 * quarter : 0
        let scroll = Double(max(0, scrollIndex)) * 1440.0 / Double(fps)
        let motionIndex = phase == "video" || phase == "mixed" ? index : 0
        // Match SCStream sourceRect (Mac points) at 2 physical pixels per point, then scale into
        // the exact output chosen by ViewportCapturePolicy. Glyphs retain their desktop-pixel size.
        let sourceRect = geometry.region.rect
        let pixelX = sourceRect.minX * 2, pixelY = sourceRect.minY * 2
        let pixelWidth = sourceRect.width * 2, pixelHeight = sourceRect.height * 2
        context.scaleBy(x: CGFloat(geometry.width) / pixelWidth, y: CGFloat(geometry.height) / pixelHeight)
        context.translateBy(x: -pixelX, y: -pixelY)
        context.setFillColor(CGColor(srgbRed: 0.075, green: 0.09, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 54))
        context.setFillColor(CGColor(srgbRed: 0.89, green: 0.91, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 20, y: 16, width: 160, height: 5))
        let font = CTFontCreateWithName("Menlo" as CFString, 22, nil) // 11 Mac points at 2× backing scale.
        let small = CTFontCreateWithName("Menlo" as CFString, 18, nil)
        let syntax = [CGColor(srgbRed: 0.55, green: 0.75, blue: 1, alpha: 1),
                      CGColor(srgbRed: 0.95, green: 0.63, blue: 0.48, alpha: 1),
                      CGColor(srgbRed: 0.83, green: 0.85, blue: 0.88, alpha: 1)]
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        for row in 0..<Int(Double(height + 1500) / 30) {
            let y = CGFloat(96 + row * 30) - CGFloat(scroll)
            if y < 48 || y >= CGFloat(height - 18) { continue }
            var state = seed &+ UInt32(row) &* 2_654_435_761
            state ^= state >> 15; state &*= 2_246_822_519; state ^= state >> 13
            let token = ["func", "let", "guard", "frame", "timestamp", "pixel", "encode", "decode", "return", "if"][Int(state % 10)]
            let line = String(format: "%03d  %@  value_%04d = frame.map { $0 + %d } // :;[]{},.", row + 1, token, Int(state % 10000), Int(state % 97))
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): row % 5 == 0 ? small : font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): syntax[row % syntax.count]]
            let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            for column in 0..<3 {
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: 24 + CGFloat(column * 850) + CGFloat(row % 4) * 10, y: y)
                CTLineDraw(shaped, context)
            }
        }
        context.restoreGState()
        // A moving video tile and frame counter prevent a static-screen-only comparison.
        let tile = CGRect(x: CGFloat(width * 2 / 3), y: CGFloat(height / 3), width: CGFloat(width / 4), height: CGFloat(height / 4))
        context.setFillColor(CGColor(srgbRed: 0.02, green: 0.03, blue: 0.05, alpha: 1)); context.fill(tile)
        for band in 0..<24 {
            let value = Double((band * 37 + motionIndex * 11) % 255) / 255
            context.setFillColor(CGColor(srgbRed: value, green: 0.25 + value * 0.4, blue: 1 - value * 0.7, alpha: 1))
            context.fill(CGRect(x: tile.minX + CGFloat(band) * tile.width / 24, y: tile.minY,
                                width: tile.width / 24 + 1, height: tile.height))
        }
        context.setFillColor(CGColor(gray: 0.98, alpha: 1))
        context.fill(CGRect(x: CGFloat(width - 130), y: 20, width: CGFloat((motionIndex % 100) + 1), height: 8))
        CVPixelBufferUnlockBaseAddress(bgra, [])
        CVBufferSetAttachment(bgra, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(bgra, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        guard VTPixelTransferSessionTransferImage(transfer, from: bgra, to: nv12) == noErr else {
            throw NSError(domain: "CodecAB", code: 2)
        }
        return FrameSource(pixels: nv12, hash: try Self.hashNV12(nv12), phase: phase)
    }

    private func pool(width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        var result: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &result) == kCVReturnSuccess, let result else {
            throw NSError(domain: "CodecAB", code: 3)
        }
        return result
    }
    private func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result else {
            throw NSError(domain: "CodecAB", code: 4)
        }
        return result
    }
    private func transferSession() throws -> VTPixelTransferSession {
        var result: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &result) == noErr, let result else {
            throw NSError(domain: "CodecAB", code: 5)
        }
        XCTAssertEqual(VTSessionSetProperty(result, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                            value: kCVImageBufferYCbCrMatrix_ITU_R_601_4), noErr)
        return result
    }

    private static func lumaRange(_ pixels: CVPixelBuffer) throws -> LumaRange {
        switch CVPixelBufferGetPixelFormatType(pixels) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return LumaRange(scale: 255.0 / 219.0, offset: -16.0 * 255.0 / 219.0, name: "420v")
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return LumaRange(scale: 1, offset: 0, name: "420f")
        default:
            throw NSError(domain: "CodecAB", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unsupported decoded luma range"])
        }
    }
    private static func withYPlanes<T>(_ source: CVPixelBuffer, _ decoded: CVPixelBuffer,
                                       _ body: (UnsafePointer<UInt8>, Int, LumaRange, UnsafePointer<UInt8>, Int, LumaRange, Int, Int) -> T) throws -> T {
        guard CVPixelBufferGetPlaneCount(source) >= 2, CVPixelBufferGetPlaneCount(decoded) >= 2,
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(decoded),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(decoded) else { throw NSError(domain: "CodecAB", code: 6) }
        let sourceRange = try lumaRange(source), decodedRange = try lumaRange(decoded)
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(source, 0), let b = CVPixelBufferGetBaseAddressOfPlane(decoded, 0) else {
            throw NSError(domain: "CodecAB", code: 7)
        }
        return body(a.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(source, 0), sourceRange,
                    b.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(decoded, 0), decodedRange,
                    CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source))
    }
    private static func psnrY(_ source: CVPixelBuffer, _ decoded: CVPixelBuffer) throws -> Double {
        try withYPlanes(source, decoded) { a, asr, ar, b, bsr, br, width, height in
            var fa = [Float](repeating: 0, count: width), fb = fa, normA = fa, normB = fa, diff = fa
            var sum: Float = 0
            for y in 0..<height {
                vDSP_vfltu8(a.advanced(by: y * asr), 1, &fa, 1, vDSP_Length(width))
                vDSP_vfltu8(b.advanced(by: y * bsr), 1, &fb, 1, vDSP_Length(width))
                var ascale = ar.scale, aoffset = ar.offset, bscale = br.scale, boffset = br.offset
                vDSP_vsmsa(&fa, 1, &ascale, &aoffset, &normA, 1, vDSP_Length(width))
                vDSP_vsmsa(&fb, 1, &bscale, &boffset, &normB, 1, vDSP_Length(width))
                vDSP_vsub(&normB, 1, &normA, 1, &diff, 1, vDSP_Length(width))
                var row: Float = 0
                vDSP_svesq(&diff, 1, &row, vDSP_Length(width))
                sum += row
            }
            let mse = Double(sum) / Double(width * height)
            return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
        }
    }
    /// Mean 8×8 luminance SSIM over a regular stride-32 grid within the text editor rectangle.
    /// Grid sampling bounds CPU work in Debug; no metric runs in a timed callback.
    private static func sampledSSIMY(_ source: CVPixelBuffer, _ decoded: CVPixelBuffer, roi: CGRect) throws -> Double {
        try withYPlanes(source, decoded) { a, asr, ar, b, bsr, br, width, height in
            let left = max(0, Int(roi.minX)), top = max(0, Int(roi.minY))
            let right = min(width - 8, Int(roi.maxX)), bottom = min(height - 8, Int(roi.maxY))
            guard right >= left, bottom >= top else { return 0 }
            var total = 0.0, windows = 0
            for y in stride(from: top, through: bottom, by: 32) {
                for x in stride(from: left, through: right, by: 32) {
                    var ax = 0.0, bx = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
                    for dy in 0..<8 { for dx in 0..<8 {
                        let p = Double(a[(y + dy) * asr + x + dx]) * Double(ar.scale) + Double(ar.offset)
                        let q = Double(b[(y + dy) * bsr + x + dx]) * Double(br.scale) + Double(br.offset)
                        ax += p; bx += q; aa += p * p; bb += q * q; ab += p * q
                    } }
                    let ma = ax / 64, mb = bx / 64
                    let va = max(0, aa / 64 - ma * ma), vb = max(0, bb / 64 - mb * mb)
                    if va < 20 { continue } // Ignore flat editor background; only text-edge windows count.
                    let cov = ab / 64 - ma * mb
                    let c1 = 6.5025, c2 = 58.5225
                    total += ((2 * ma * mb + c1) * (2 * cov + c2)) /
                             ((ma * ma + mb * mb + c1) * (va + vb + c2))
                    windows += 1
                }
            }
            return windows == 0 ? 0 : total / Double(windows)
        }
    }
    private static func hashNV12(_ pixels: CVPixelBuffer) throws -> String {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else {
            throw NSError(domain: "CodecAB", code: 8)
        }
        let y = yBase.assumingMemoryBound(to: UInt8.self), uv = uvBase.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        var tight = Data(count: width * height * 3 / 2)
        tight.withUnsafeMutableBytes { raw in
            guard let output = raw.baseAddress else { return }
            for row in 0..<height { memcpy(output.advanced(by: row * width), y.advanced(by: row * yStride), width) }
            let uvOffset = width * height
            for row in 0..<(height / 2) {
                memcpy(output.advanced(by: uvOffset + row * width), uv.advanced(by: row * uvStride), width)
            }
        }
        return SHA256.hash(data: tight).map { String(format: "%02x", $0) }.joined()
    }
    private func writePNG(_ pixels: CVPixelBuffer, rect: CGRect, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let crop = ci.createCGImage(image, from: rect),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "CodecAB", code: 9)
        }
        CGImageDestinationAddImage(destination, crop, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private static func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Any {
        guard !values.isEmpty else { return NSNull() }
        let sorted = values.sorted(), index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return round(sorted[index])
    }

    func testSampledSSIMIdentityAndDegradation() throws {
        func make(_ mark: UInt8, low: UInt8 = 16,
                  format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CVPixelBuffer {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, format,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<64 { for x in 0..<64 { base[y * stride + x] = (x / 4 + y / 4) % 2 == 0 ? mark : low } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        let a = try make(235), b = try make(80)
        let sameFullRange = try make(255, low: 0, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(try Self.sampledSSIMY(a, a, roi: CGRect(x: 0, y: 0, width: 64, height: 64)), 1, accuracy: 0.00001)
        XCTAssertEqual(try Self.sampledSSIMY(a, sameFullRange, roi: CGRect(x: 0, y: 0, width: 64, height: 64)), 1, accuracy: 0.00001)
        XCTAssertLessThan(try Self.sampledSSIMY(a, b, roi: CGRect(x: 0, y: 0, width: 64, height: 64)), 0.9)
        XCTAssertEqual(try Self.psnrY(a, a), 99)
        XCTAssertGreaterThan(try Self.psnrY(a, sameFullRange), 90)
        XCTAssertLessThan(try Self.psnrY(a, b), 20)
    }
}
