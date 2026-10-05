import XCTest
import CoreGraphics
import CoreText
import CoreVideo
import VideoToolbox

/// Opt-in HEVC 4:2:0 feasibility spike (Docs/perf/HEVC-SPIKE.md): hardware encode latency of H.264 against HEVC at
/// the stream sizes that matter for 120 fps, HEVC's low-latency mode, and bench-chart legibility per bitrate. The
/// Printed tables are the deliverable; session creation and complete, error-free callbacks are required,
/// while latency has no pass threshold. Encoding is unpaced: the next frame goes in as soon as a slot frees,
/// so one frame in flight measures VideoToolbox's service time per frame.
/// Run: TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 xcodebuild test … -only-testing:RemoteCoreTests/HEVCProbeTests
final class HEVCProbeTests: XCTestCase {
    struct Codec {
        let name: String
        let type: CMVideoCodecType
        let profile: CFString
    }

    struct Setup {
        var codec: Codec
        var width: Int
        var height: Int
        var fps: Int
        var bitrate: Int
        var lowLatency = false
    }

    static let h264 = Codec(name: "H.264", type: kCMVideoCodecType_H264, profile: kVTProfileLevel_H264_High_AutoLevel)
    static let hevc = Codec(name: "HEVC", type: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
    /// Built-in panel as streamed, the ASUS at 1440p, and the iPhone 17's own pixels.
    static let sizes = [(2560, 1656), (2560, 1440), (2622, 1206)]
    static let frameCount = 120

    override func setUpWithError() throws {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["POCKETDESK_HEVC_PROBE"] == "1" else {
            throw XCTSkip("Set POCKETDESK_HEVC_PROBE=1 (TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 with xcodebuild) to run.")
        }
        print("HEVC PROBE conditions: \(Self.conditions())")
        #else
        throw XCTSkip("HEVC probes require a Debug test configuration.")
        #endif
    }

    func testEncodeLatencyOneFrameInFlight() throws {
        try latencyTable(inFlight: 1)
    }

    func testEncodeLatencyThreeFramesInFlight() throws {
        try latencyTable(inFlight: 3)
    }

    func testHEVCLowLatencyModeOnce() throws {
        let source = try ScrollingPage(width: 2560, height: 1656, frames: Self.frameCount)
        print("HEVC PROBE low-latency rate control, 2560x1656, 120 fps, 12 Mb/s, \(Self.frameCount) scrolling frames")
        print("HEVC PROBE " + Self.header)
        let standard = Setup(codec: Self.hevc, width: 2560, height: 1656, fps: 120, bitrate: 12_000_000)
        var lowLatency = standard
        lowLatency.lowLatency = true
        for (setup, inFlight) in [(standard, 1), (lowLatency, 1), (lowLatency, 3)] {
            guard let encoder = ProbeEncoder(setup) ??
                (setup.lowLatency ? ProbeEncoder(setup, requireHardware: false) : nil) else {
                print("HEVC PROBE \(Self.label(setup, inFlight: inFlight)): session not created")
                if !setup.lowLatency { XCTFail("standard HEVC hardware session") }
                continue
            }
            let run = try encoder.run(count: Self.frameCount, inFlight: inFlight, frame: source.frame)
            print("HEVC PROBE " + Self.row(setup, inFlight: inFlight, encoder: encoder, run: run))
        }
    }

    /// The bench chart (seed 1449, the session's seed) on a static code desktop at the session's geometry: a
    /// 1920x1242 pt display at 4/3 px per pt, streamed at 2560x1656. 30 static frames per codec and bitrate, the last
    /// one decoded and scored with Vision. The 60 fps sessions logged no on-stream 11 pt CER, so the target is the
    /// unencoded 4:2:0 frame's 11 pt CER plus one character (1 of the 64 in the 11 pt cells), unless
    /// POCKETDESK_HEVC_TARGET_CER11 (percent) supplies the session figure.
    func testLegibilityPerBitrate() throws {
        let seed: UInt16 = 1449
        let width = 2560, height = 1656, scale: CGFloat = 4.0 / 3
        let layout = LegibilityChart.layout(displayPointSize: CGSize(width: 1920, height: 1242))
        let rgb = try Frames.bgra(width: width, height: height) { context in
            Frames.drawCode(in: context, width: width, height: height)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(layout.frame.insetBy(dx: -16, dy: -16))
            LegibilityChartRenderer.draw(cells: LegibilityChart.cells(seed: seed), layout: layout, in: context)
        }
        let source = try Frames.nv12(from: rgb)
        let unencoded = try Frames.bgra(from: source)
        let chart = layout.frame.insetBy(dx: -8, dy: -8)
        let crop = CGRect(x: chart.minX * scale, y: chart.minY * scale,
                          width: chart.width * scale, height: chart.height * scale).integral
        func score(_ buffer: CVPixelBuffer) throws -> [String: Double] {
            let image = try XCTUnwrap(Frames.image(of: buffer)?.cropping(to: crop), "chart crop")
            return try LegibilityScore.score(image: image, seed: seed).cerBySize
        }
        let ceilingRGB = try score(rgb)
        let ceiling420 = try score(unencoded)
        let override = ProcessInfo.processInfo.environment["POCKETDESK_HEVC_TARGET_CER11"].flatMap(Double.init)
        let target = override ?? (ceiling420["11pt"] ?? 0) + 100.0 / 64
        print("HEVC PROBE legibility, seed \(seed), 2560x1656 static chart, 60 fps, 30 frames, last frame decoded")
        print("HEVC PROBE codec   Mb/s    9pt   11pt   13pt   15pt  col11  chartPSNR   IDR KB  P KB avg")
        print("HEVC PROBE " + Self.cerRow("RGB", "-", ceilingRGB, psnr: nil, keyKB: nil, deltaKB: nil))
        let unencodedPSNR = Frames.psnr(unencoded, rgb, in: crop)
        print("HEVC PROBE " + Self.cerRow("4:2:0", "-", ceiling420, psnr: unencodedPSNR, keyKB: nil, deltaKB: nil))
        for codec in [Self.h264, Self.hevc] {
            var reached: Int?
            for megabits in [1, 2, 4, 8, 12] {
                let setup = Setup(codec: codec, width: width, height: height, fps: 60, bitrate: megabits * 1_000_000)
                guard let encoder = ProbeEncoder(setup) else {
                    XCTFail("\(codec.name) hardware session at \(megabits) Mb/s")
                    continue
                }
                let run = try encoder.run(count: 30, inFlight: 1, keepSamples: true) { _ in source }
                let decoded = try Frames.decodeLast(run.samples)
                let cer = try score(decoded)
                let deltaKB = Self.mean(run.deltaBytes.map(Double.init)) / 1024
                let psnr = Frames.psnr(decoded, rgb, in: crop)
                print("HEVC PROBE " + Self.cerRow(codec.name, "\(megabits)", cer, psnr: psnr,
                                                  keyKB: Double(run.keyBytes) / 1024, deltaKB: deltaKB))
                if reached == nil, (cer["11pt"] ?? 100) <= target { reached = megabits }
            }
            let verdict = reached.map { "\($0) Mb/s" } ?? "not within 12 Mb/s"
            print("HEVC PROBE \(codec.name) reaches 11 pt CER <= \(String(format: "%.1f", target)) % at: \(verdict)")
        }
    }

    private func latencyTable(inFlight: Int) throws {
        print("HEVC PROBE encode latency, \(inFlight) in flight, \(Self.frameCount) scrolling code frames, " +
              "ms from submit to callback (IDR excluded from p50/p90/max)")
        print("HEVC PROBE " + Self.header)
        for (width, height) in Self.sizes {
            let source = try ScrollingPage(width: width, height: height, frames: Self.frameCount)
            for codec in [Self.h264, Self.hevc] {
                for fps in [60, 120] {
                    for bitrate in [12_000_000, 25_000_000] {
                        let setup = Setup(codec: codec, width: width, height: height, fps: fps, bitrate: bitrate)
                        guard let encoder = ProbeEncoder(setup) else {
                            XCTFail("\(Self.label(setup, inFlight: inFlight)): hardware session not created")
                            continue
                        }
                        let run = try encoder.run(count: Self.frameCount, inFlight: inFlight, frame: source.frame)
                        print("HEVC PROBE " + Self.row(setup, inFlight: inFlight, encoder: encoder, run: run))
                    }
                }
            }
        }
    }

    static let header = "codec    size       fps Mb/s fly |   p50   p90   max | IDR ms | enc fps | P KB IDR KB " +
        "| encoder"

    static func label(_ setup: Setup, inFlight: Int) -> String {
        "\(setup.codec.name) \(setup.lowLatency ? "LL " : "")\(setup.width)x\(setup.height) \(setup.fps) fps " +
            "\(setup.bitrate / 1_000_000) Mb/s \(inFlight) in flight"
    }

    private static func row(_ setup: Setup, inFlight: Int, encoder: ProbeEncoder, run: EncodeRun) -> String {
        let sorted = run.latencies.sorted()
        let fields = [
            pad(setup.codec.name + (setup.lowLatency ? " LL" : ""), 8), pad("\(setup.width)x\(setup.height)", 10),
            pad("\(setup.fps)", 3, left: true), pad("\(setup.bitrate / 1_000_000)", 4, left: true),
            pad("\(inFlight)", 3, left: true), "|", number(percentile(sorted, 0.5)), number(percentile(sorted, 0.9)),
            number(sorted.last ?? .nan), "|", number(run.keyMs, width: 6), "|",
            number(run.throughputFPS, width: 7), "|",
            number(mean(run.deltaBytes.map(Double.init)) / 1024, width: 4, digits: 0),
            number(Double(run.keyBytes) / 1024, width: 6, digits: 0), "|", encoder.summary,
            "attempted=\(run.attempted) delivered=\(run.delivered) dropped=\(run.dropped) errors=\(run.errors)"
        ]
        return fields.joined(separator: " ")
    }

    static func cerRow(_ name: String, _ megabits: String, _ cer: [String: Double], psnr: Double?,
                       keyKB: Double?, deltaKB: Double?) -> String {
        let sizes = ["9pt", "11pt", "13pt", "15pt", "coloured11pt"].map { number(cer[$0] ?? .nan, width: 5) }
        return ([pad(name, 5), pad(megabits, 5, left: true)] + sizes + [
            psnr.map { number($0, width: 9) } ?? pad("-", 9, left: true),
            keyKB.map { number($0, width: 7, digits: 0) } ?? pad("-", 7, left: true),
            deltaKB.map { number($0, width: 8, digits: 1) } ?? pad("-", 8, left: true)
        ]).joined(separator: "  ")
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    static func number(_ value: Double, width: Int = 5, digits: Int = 1) -> String {
        pad(value.isFinite ? String(format: "%.\(digits)f", value) : "-", width, left: true)
    }

    static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        guard text.count < width else { return text }
        let fill = String(repeating: " ", count: width - text.count)
        return left ? fill + text : text + fill
    }

    static func conditions() -> String {
        var load = [Double](repeating: 0, count: 3)
        let loaded = getloadavg(&load, 3) == 3
        let info = ProcessInfo.processInfo
        return "load \(loaded ? load.map { String(format: "%.1f", $0) }.joined(separator: " ") : "?") · " +
            "thermal \(info.thermalState.rawValue) · low power \(info.isLowPowerModeEnabled) · " +
            "\(NativeCodecCapability.systemAndModel)"
    }
}

private struct EncodeRun {
    var latencies: [Double] = []
    var keyMs = Double.nan
    var throughputFPS = Double.nan
    var keyBytes = 0
    var deltaBytes: [Int] = []
    var samples: [CMSampleBuffer] = []
    var attempted = 0
    var delivered = 0
    var dropped = 0
    var errors = 0
}

private struct HEVCProbeError: Error, CustomStringConvertible {
    let description: String
}

private final class ProbeEncoder {
    typealias Setup = HEVCProbeTests.Setup
    let session: VTCompressionSession
    let setup: Setup
    let requiredHardware: Bool
    private(set) var rejected: [String] = []
    private(set) var encoderID = "?"
    private(set) var hardware = "?"

    var summary: String {
        let name = encoderID.split(separator: ".").suffix(2).joined(separator: ".")
        let flags = (requiredHardware ? [] : ["hw not required"]) + rejected.map { "rejected " + $0 }
        return "\(name) hw=\(hardware)" + (flags.isEmpty ? "" : " (" + flags.joined(separator: ", ") + ")")
    }

    init?(_ setup: Setup, requireHardware: Bool = true) {
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if requireHardware { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        if setup.lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(setup.width), height: Int32(setup.height),
                                         codecType: setup.codec.type,
                                         encoderSpecification: specification as CFDictionary,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &created) == noErr,
              let created else { return nil }
        session = created
        self.setup = setup
        requiredHardware = requireHardware
        let properties: [(String, CFString, CFTypeRef)] = [
            ("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            ("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            ("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, setup.codec.profile),
            ("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, setup.fps as CFNumber),
            ("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, setup.bitrate as CFNumber),
            ("MaxKeyFrameInterval", kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber),
            ("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber)
        ]
        for (name, key, value) in properties {
            let status = VTSessionSetProperty(created, key: key, value: value)
            if status != noErr { rejected.append("\(name)(\(status))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        encoderID = (copyProperty(kVTCompressionPropertyKey_EncoderID) as? String) ?? "?"
        hardware = (copyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool)
            .map { "\($0)" } ?? "unreported"
    }

    deinit { VTCompressionSessionInvalidate(session) }

    private func copyProperty(_ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        return status == noErr ? value : nil
    }

    /// At most `inFlight` frames inside VideoToolbox; frame 0 is a forced key frame and is reported on its own.
    func run(count: Int, inFlight: Int, keepSamples: Bool = false,
             frame: (Int) -> CVPixelBuffer) throws -> EncodeRun {
        let recorder = EncodeRecorder(count: count, keepSamples: keepSamples)
        let timescale = CMTimeScale(setup.fps)
        let key = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        for index in 0..<count {
            guard recorder.waitForCapacity(inFlight, until: Date(timeIntervalSinceNow: 5)) else {
                throw HEVCProbeError(description: "encode callback timeout: \(recorder.counts)")
            }
            let buffer = frame(index)
            recorder.submitted(index, at: CACurrentMediaTime())
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: timescale),
                duration: CMTime(value: 1, timescale: timescale), frameProperties: index == 0 ? key : nil,
                infoFlagsOut: nil
            ) { status, flags, sample in
                recorder.completed(index, at: CACurrentMediaTime(), status: status,
                                   dropped: flags.contains(.frameDropped), sample: sample)
            }
            if status != noErr {
                recorder.completed(index, at: CACurrentMediaTime(), status: status, dropped: false, sample: nil)
            }
        }
        guard recorder.waitForCapacity(1, until: Date(timeIntervalSinceNow: 5)) else {
            throw HEVCProbeError(description: "encode drain timeout: \(recorder.counts)")
        }
        let result = recorder.result()
        guard result.delivered == count, result.dropped == 0, result.errors == 0 else {
            throw HEVCProbeError(description: "incomplete encode probe: \(recorder.counts)")
        }
        return result
    }
}

private final class EncodeRecorder: @unchecked Sendable {
    private let lock = NSCondition()
    private let keepSamples: Bool
    private var submittedAt: [Double]
    private var latencies: [Double?]
    private var bytes: [Int]
    private var samples: [CMSampleBuffer?]
    private var lastCompletion = 0.0
    private var pending = 0
    private var attempted = 0
    private var dropped = 0
    private var errors = 0

    init(count: Int, keepSamples: Bool) {
        self.keepSamples = keepSamples
        submittedAt = Array(repeating: 0, count: count)
        latencies = Array(repeating: nil, count: count)
        bytes = Array(repeating: 0, count: count)
        samples = Array(repeating: nil, count: count)
    }

    func submitted(_ index: Int, at time: Double) {
        lock.lock()
        submittedAt[index] = time
        attempted += 1
        pending += 1
        lock.unlock()
    }

    func waitForCapacity(_ maximumPending: Int, until deadline: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        while pending >= maximumPending {
            if !lock.wait(until: deadline), pending >= maximumPending { return false }
        }
        return true
    }

    var counts: String {
        lock.lock(); defer { lock.unlock() }
        let delivered = bytes.filter { $0 > 0 }.count
        return "attempted=\(attempted) delivered=\(delivered) dropped=\(dropped) errors=\(errors) pending=\(pending)"
    }

    func completed(_ index: Int, at time: Double, status: OSStatus,
                   dropped wasDropped: Bool, sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard latencies[index] == nil else { return }
        latencies[index] = (time - submittedAt[index]) * 1000
        pending -= 1
        if status == noErr, !wasDropped, let sample, let data = CMSampleBufferGetDataBuffer(sample),
           CMBlockBufferGetDataLength(data) > 0 {
            lastCompletion = max(lastCompletion, time)
            bytes[index] = CMBlockBufferGetDataLength(data)
            if keepSamples { samples[index] = sample }
        } else {
            bytes[index] = -1
            if wasDropped { dropped += 1 } else { errors += 1 }
        }
        lock.broadcast()
    }

    func result() -> EncodeRun {
        lock.lock(); defer { lock.unlock() }
        var run = EncodeRun()
        run.keyMs = latencies.first.flatMap { $0 } ?? .nan
        run.keyBytes = max(0, bytes.first ?? 0)
        run.latencies = zip(latencies, bytes).dropFirst().compactMap { $1 >= 0 ? $0 : nil }
        run.deltaBytes = bytes.dropFirst().filter { $0 >= 0 }
        run.attempted = attempted
        run.delivered = bytes.filter { $0 > 0 }.count
        run.dropped = dropped
        run.errors = errors
        run.samples = samples.compactMap { $0 }
        if submittedAt.count > 1, lastCompletion > submittedAt[1] {
            let deliveredDeltas = bytes.dropFirst().filter { $0 > 0 }.count
            run.throughputFPS = Double(deliveredDeltas) / (lastCompletion - submittedAt[1])
        }
        return run
    }
}

/// A tall code page rendered once and scrolled `step` pixels per frame by copying NV12 rows into a ring of buffers
/// (deeper than any in-flight count), so rendering stays out of the encode timing.
private final class ScrollingPage {
    static let step = 12
    let width: Int
    let height: Int
    private let page: CVPixelBuffer
    private let ring: [CVPixelBuffer]

    init(width: Int, height: Int, frames: Int) throws {
        self.width = width
        self.height = height
        let pageHeight = height + frames * Self.step
        page = try Frames.nv12(from: try Frames.bgra(width: width, height: pageHeight) {
            Frames.drawCode(in: $0, width: width, height: pageHeight)
        })
        ring = try (0..<6).map { _ in try Frames.makeBuffer(width: width, height: height, format: Frames.nv12Format) }
    }

    func frame(_ index: Int) -> CVPixelBuffer {
        let buffer = ring[index % ring.count]
        let offset = (index * Self.step) & ~1
        CVPixelBufferLockBaseAddress(page, .readOnly); CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []); CVPixelBufferUnlockBaseAddress(page, .readOnly) }
        for plane in 0..<2 {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(page, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(page, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), first = plane == 0 ? offset : offset / 2
            for row in 0..<rows {
                memcpy(to + row * toStride, from + (first + row) * fromStride, min(fromStride, toStride))
            }
        }
        return buffer
    }
}

private enum Frames {
    static let nv12Format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        if format == nv12Format {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                  .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                                  .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                                  .shouldPropagate)
        }
        return buffer
    }

    /// BGRA buffer drawn through a flipped context: top-left origin, one unit per pixel.
    static func bgra(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                        CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw XCTSkip("no BGRA context")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return buffer
    }

    static func transfer(_ source: CVPixelBuffer, to format: OSType) throws -> CVPixelBuffer {
        let destination = try makeBuffer(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
                                         format: format)
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let session = created else { throw XCTSkip("no pixel transfer session") }
        defer { VTPixelTransferSessionInvalidate(session) }
        if format == nv12Format {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_709_2)
        }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            throw XCTSkip("pixel transfer failed")
        }
        return destination
    }

    static func nv12(from bgra: CVPixelBuffer) throws -> CVPixelBuffer { try transfer(bgra, to: nv12Format) }

    static func bgra(from nv12: CVPixelBuffer) throws -> CVPixelBuffer {
        try transfer(nv12, to: kCVPixelFormatType_32BGRA)
    }

    static func image(of bgra: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(bgra, .readOnly); defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        return CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: CVPixelBufferGetWidth(bgra),
                         height: CVPixelBufferGetHeight(bgra), bitsPerComponent: 8,
                         bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                            CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
    }

    /// RGB PSNR of two BGRA buffers inside `rect` (pixels, top-left origin), every other pixel.
    static func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in rect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return .nan }
        let strideA = CVPixelBufferGetBytesPerRow(a), strideB = CVPixelBufferGetBytesPerRow(b)
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(a),
                                              height: CVPixelBufferGetHeight(a)))
        var squared = 0.0, count = 0.0
        for y in stride(from: Int(bounds.minY), to: Int(bounds.maxY), by: 2) {
            for x in stride(from: Int(bounds.minX), to: Int(bounds.maxX), by: 2) {
                for channel in 0..<3 {
                    let diff = Double(pa[y * strideA + x * 4 + channel]) - Double(pb[y * strideB + x * 4 + channel])
                    squared += diff * diff
                    count += 1
                }
            }
        }
        let mse = squared / max(1, count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// Decodes every sample in order and returns the last picture as BGRA.
    static func decodeLast(_ samples: [CMSampleBuffer]) throws -> CVPixelBuffer {
        guard let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) else {
            throw HEVCProbeError(description: "legibility decode has no encoded sample/format")
        }
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as [CFString: Any]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr,
              let decoder = created else { throw HEVCProbeError(description: "legibility decoder session failed") }
        defer { VTDecompressionSessionInvalidate(decoder) }
        var last: CVPixelBuffer?
        for sample in samples {
            let result = MacDecodeResult()
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                                                           flags: ._EnableAsynchronousDecompression,
                                                           infoFlagsOut: nil) {
                status, flags, image, _, _ in
                result.complete(status: status, image: flags.contains(.frameDropped) ? nil : image)
            }
            guard status == noErr else {
                throw HEVCProbeError(description: "legibility decode submit failed: \(status)")
            }
            last = try result.wait(until: Date(timeIntervalSinceNow: 5))
        }
        guard let last else { throw HEVCProbeError(description: "legibility decode delivered no image") }
        return last
    }

    /// An editor-like page: gutter numbers, keyword, string and comment colours, and a selection band every 11 lines,
    /// in two panes so text covers the full width.
    static func drawCode(in context: CGContext, width: Int, height: Int) {
        let lines = ["func configureNativeSender(quality: StreamQuality) -> RTCRtpParameters {",
                     "    let parameters = sender.parameters // max 20_000_000 bps, start 8_000_000",
                     "    guard let encoding = parameters.encodings.first else { return parameters }",
                     "    encoding.rid = \"desktop\" + String(parameters.encodings.count)",
                     "error: cannot convert value of type '[String: Any]' to expected argument type 'Int32'",
                     "  0x00007ff8 in PeerMedia.publishStreamStatistics(_:) + 412 at PeerMedia.swift:233",
                     "    // HEVC Main 4:2:0 at 2560x1656, 120 fps, one frame in flight",
                     "}"]
        let space = CGColorSpaceCreateDeviceRGB()
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
        }
        let plain = colour(0.1, 0.1, 0.1), keyword = colour(0.61, 0.14, 0.58), string = colour(0.77, 0.1, 0.09)
        let comment = colour(0, 0.45, 0), gutter = colour(0.55, 0.55, 0.55), selection = colour(0.8, 0.88, 1)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 22, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colourKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let lineHeight = 30, pane = width / 2
        for row in 0..<(height / lineHeight + 1) {
            if row % 11 == 5 {
                context.setFillColor(selection)
                context.fill(CGRect(x: 0, y: row * lineHeight, width: width, height: lineHeight))
            }
            for column in 0..<2 {
                let text = lines[(row + column * 3) % lines.count]
                let attributed = NSMutableAttributedString(string: text, attributes: [fontKey: font, colourKey: plain])
                if let slashes = text.range(of: "//") {
                    attributed.addAttribute(colourKey, value: comment,
                                            range: NSRange(slashes.lowerBound..<text.endIndex, in: text))
                }
                for word in ["func ", "let ", "guard ", "else ", "return "] {
                    let range = (text as NSString).range(of: word)
                    if range.location != NSNotFound { attributed.addAttribute(colourKey, value: keyword, range: range) }
                }
                if let open = text.firstIndex(of: "\""),
                   let close = text[text.index(after: open)...].firstIndex(of: "\"") {
                    attributed.addAttribute(colourKey, value: string, range: NSRange(open...close, in: text))
                }
                let number = NSAttributedString(string: String(format: "%4d", row + 1),
                                                attributes: [fontKey: font, colourKey: gutter])
                let baseline = CGFloat(row * lineHeight + 22)
                context.textPosition = CGPoint(x: CGFloat(column * pane + 8), y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(number), context)
                context.textPosition = CGPoint(x: CGFloat(column * pane + 80), y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
    }
}

private final class MacDecodeResult: @unchecked Sendable {
    private let lock = NSCondition()
    private var stored: CVImageBuffer?
    private var status: OSStatus?
    func complete(status: OSStatus, image: CVImageBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard self.status == nil else { return }
        self.status = status
        stored = image
        lock.broadcast()
    }
    func wait(until deadline: Date) throws -> CVImageBuffer {
        lock.lock(); defer { lock.unlock() }
        while status == nil {
            if !lock.wait(until: deadline), status == nil {
                throw HEVCProbeError(description: "legibility decode callback timeout")
            }
        }
        guard status == noErr, let stored else {
            throw HEVCProbeError(description: "legibility decode callback failed: \(status ?? -1)")
        }
        return stored
    }
}
