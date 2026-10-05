import XCTest
import CoreGraphics
import CoreText
import CoreVideo
import VideoToolbox

/// Device-only HEVC spike probe (Docs/perf/HEVC-SPIKE.md): the phone's own hardware encoder produces H.264 and HEVC
/// streams of scrolling code frames, then a hardware VTDecompressionSession configured like libwebrtc's H.264 decoder
/// (NV12 full range, IOSurface, asynchronous) decodes them with one frame in flight. Reports decode p50/p90 per codec
/// and size; session creation and complete, error-free callbacks are required, with no latency pass threshold.
/// Run on the device with TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 and
/// -only-testing:RemotePhoneTests/HEVCDecodeProbeTests.
final class HEVCDecodeProbeTests: XCTestCase {
    private struct Codec {
        let name: String
        let type: CMVideoCodecType
        let profile: CFString
    }

    private static let codecs = [
        Codec(name: "H.264", type: kCMVideoCodecType_H264, profile: kVTProfileLevel_H264_High_AutoLevel),
        Codec(name: "HEVC", type: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
    ]
    /// The Mac's built-in panel as streamed, and the iPhone 17's own pixels.
    private static let sizes = [(2560, 1656), (2622, 1206)]
    private static let frameCount = 120
    private static let fps = 120
    private static let bitrate = 25_000_000

    func testHardwareDecodeLatency() throws {
        #if !DEBUG
        throw XCTSkip("HEVC probes require a Debug test configuration.")
        #elseif targetEnvironment(simulator)
        throw XCTSkip("Device-only probe: the simulator has no hardware video codecs.")
        #else
        guard ProcessInfo.processInfo.environment["POCKETDESK_HEVC_PROBE"] == "1" else {
            throw XCTSkip("Set POCKETDESK_HEVC_PROBE=1 (TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 with xcodebuild) to run.")
        }
        let info = ProcessInfo.processInfo
        print("HEVC DECODE PROBE \(Self.model()) iOS \(info.operatingSystemVersionString) · thermal " +
              "\(info.thermalState.rawValue) · low power \(info.isLowPowerModeEnabled) · hardware decode " +
              "H.264=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) " +
              "HEVC=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")
        print("HEVC DECODE PROBE \(Self.frameCount) scrolling frames, encoded here at \(Self.fps) fps " +
              "\(Self.bitrate / 1_000_000) Mb/s one in flight, decoded one in flight; ms submit to callback")
        print("HEVC DECODE PROBE codec size       | enc p50 enc p90 | dec p50 dec p90 dec max | dec fps | P KB " +
              "IDR KB | decoder hw")
        for (width, height) in Self.sizes {
            let page = try PhonePage(width: width, height: height, frames: Self.frameCount)
            for codec in Self.codecs {
                let encoded = try Self.encode(codec, page: page)
                let decoded = try Self.decode(encoded.samples)
                let deltaKB = encoded.bytes.dropFirst().reduce(0, +) / max(1, encoded.bytes.count - 1) / 1024
                let fields = [
                    Self.pad(codec.name, 5), Self.pad("\(width)x\(height)", 10), "|",
                    Self.number(Self.percentile(encoded.latencies, 0.5), 7),
                    Self.number(Self.percentile(encoded.latencies, 0.9), 7), "|",
                    Self.number(Self.percentile(decoded.latencies, 0.5), 7),
                    Self.number(Self.percentile(decoded.latencies, 0.9), 7),
                    Self.number(decoded.latencies.max() ?? .nan, 7), "|", Self.number(decoded.fps, 7), "|",
                    Self.pad("\(deltaKB)", 4, left: true),
                    Self.pad("\((encoded.bytes.first ?? 0) / 1024)", 6, left: true),
                    "|", decoded.hardware,
                    "encode attempted=\(encoded.attempted) delivered=\(encoded.samples.count) " +
                        "dropped=\(encoded.dropped) errors=\(encoded.errors)",
                    "decode attempted=\(decoded.attempted) delivered=\(decoded.delivered) " +
                        "dropped=\(decoded.dropped) errors=\(decoded.errors)"
                ]
                print("HEVC DECODE PROBE " + fields.joined(separator: " "))
            }
        }
        #endif
    }

    private struct Encoded {
        var samples: [CMSampleBuffer] = []
        var latencies: [Double] = []
        var bytes: [Int] = []
        var attempted = 0
        var dropped = 0
        var errors = 0
    }

    private struct Decoded {
        var latencies: [Double] = []
        var fps = Double.nan
        var hardware = "?"
        var attempted = 0
        var delivered = 0
        var dropped = 0
        var errors = 0
    }

    private struct EncodeOutcome {
        let status: OSStatus
        let dropped: Bool
        let sample: CMSampleBuffer?
        let completedAt: Double
    }

    private struct DecodeOutcome {
        let status: OSStatus
        let dropped: Bool
        let imageDelivered: Bool
        let completedAt: Double
    }

    private static func encode(_ codec: Codec, page: PhonePage) throws -> Encoded {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(page.width), height: Int32(page.height),
                                         codecType: codec.type, encoderSpecification: specification,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &created) == noErr,
              let session = created else {
            throw HEVCDecodeProbeError(description: "\(codec.name) hardware encoder session not created")
        }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec.profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        let key = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        var result = Encoded()
        for index in 0..<frameCount {
            let resultBox = PhoneProbeCallback<EncodeOutcome>()
            let frame = page.frame(index)
            let started = CACurrentMediaTime()
            result.attempted += 1
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: frame,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: index == 0 ? key : nil,
                infoFlagsOut: nil
            ) { status, flags, sample in
                resultBox.complete(EncodeOutcome(status: status, dropped: flags.contains(.frameDropped),
                                                  sample: sample, completedAt: CACurrentMediaTime()))
            }
            guard status == noErr else {
                throw HEVCDecodeProbeError(description: "encode submit failed: \(status), " +
                    "attempted=\(result.attempted) delivered=\(result.samples.count) errors=1")
            }
            let outcome = try resultBox.wait(until: Date(timeIntervalSinceNow: 5),
                phase: "encode attempted=\(result.attempted) delivered=\(result.samples.count)")
            if outcome.dropped { result.dropped += 1 }
            if !outcome.dropped, outcome.status != noErr || outcome.sample == nil { result.errors += 1 }
            guard outcome.status == noErr, !outcome.dropped, let sample = outcome.sample else {
                throw HEVCDecodeProbeError(description: "encode callback failed: \(outcome.status), " +
                    "attempted=\(result.attempted) delivered=\(result.samples.count) " +
                    "dropped=\(result.dropped) errors=\(result.errors)")
            }
            if index > 0 { result.latencies.append((outcome.completedAt - started) * 1000) }
            result.samples.append(sample)
            result.bytes.append(CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0)
        }
        return result
    }

    private static func decode(_ samples: [CMSampleBuffer]) throws -> Decoded {
        guard let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) else {
            throw HEVCDecodeProbeError(description: "decode has no encoded sample/format")
        }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as [CFString: Any]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                           decoderSpecification: specification,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr,
              let session = created else {
            throw HEVCDecodeProbeError(description: "hardware decoder session not created")
        }
        defer { VTDecompressionSessionInvalidate(session) }
        var result = Decoded()
        var decodeStarted = 0.0
        var lastDelivery = 0.0
        var deliveredDeltas = 0
        for (index, sample) in samples.enumerated() {
            let resultBox = PhoneProbeCallback<DecodeOutcome>()
            let started = CACurrentMediaTime()
            if index == 1 { decodeStarted = started }
            result.attempted += 1
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                           flags: ._EnableAsynchronousDecompression,
                                                           infoFlagsOut: nil) { status, flags, image, _, _ in
                resultBox.complete(DecodeOutcome(status: status, dropped: flags.contains(.frameDropped),
                    imageDelivered: image != nil, completedAt: CACurrentMediaTime()))
            }
            guard status == noErr else {
                throw HEVCDecodeProbeError(description: "decode submit failed: \(status), " +
                    "attempted=\(result.attempted) delivered=\(result.delivered) errors=1")
            }
            let outcome = try resultBox.wait(until: Date(timeIntervalSinceNow: 5),
                phase: "decode attempted=\(result.attempted) delivered=\(result.delivered)")
            if outcome.dropped { result.dropped += 1 }
            if !outcome.dropped, outcome.status != noErr || !outcome.imageDelivered { result.errors += 1 }
            guard outcome.status == noErr, !outcome.dropped, outcome.imageDelivered else {
                throw HEVCDecodeProbeError(description: "decode callback failed: \(outcome.status), " +
                    "attempted=\(result.attempted) delivered=\(result.delivered) " +
                    "dropped=\(result.dropped) errors=\(result.errors)")
            }
            result.delivered += 1
            lastDelivery = outcome.completedAt
            if index > 0 {
                deliveredDeltas += 1
                result.latencies.append((outcome.completedAt - started) * 1000)
            }
        }
        if deliveredDeltas > 0, lastDelivery > decodeStarted {
            result.fps = Double(deliveredDeltas) / (lastDelivery - decodeStarted)
        }
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        result.hardware = status == noErr ? "\((value as? Bool) ?? false)" : "unreported(\(status))"
        return result
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    private static func number(_ value: Double, _ width: Int) -> String {
        pad(value.isFinite ? String(format: "%.1f", value) : "-", width, left: true)
    }

    private static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        guard text.count < width else { return text }
        let fill = String(repeating: " ", count: width - text.count)
        return left ? fill + text : text + fill
    }

    private static func model() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

private struct HEVCDecodeProbeError: Error, CustomStringConvertible {
    let description: String
}

private final class PhoneProbeCallback<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    func complete(_ value: Value) {
        condition.lock(); defer { condition.unlock() }
        guard self.value == nil else { return }
        self.value = value
        condition.broadcast()
    }

    func wait(until deadline: Date, phase: String) throws -> Value {
        condition.lock(); defer { condition.unlock() }
        while value == nil {
            if !condition.wait(until: deadline), value == nil {
                throw HEVCDecodeProbeError(description: "\(phase): callback timeout")
            }
        }
        guard let value else { throw HEVCDecodeProbeError(description: "\(phase): missing callback result") }
        return value
    }
}

/// A tall code page rendered once (CoreGraphics into BGRA, VTPixelTransferSession to NV12) and scrolled 12 px per
/// frame by copying rows into a small ring, so rendering stays out of the timings.
private final class PhonePage {
    static let step = 12
    let width: Int
    let height: Int
    private let page: CVPixelBuffer
    private let ring: [CVPixelBuffer]

    init(width: Int, height: Int, frames: Int) throws {
        self.width = width
        self.height = height
        let pageHeight = height + frames * Self.step
        let bgra = try Self.buffer(width: width, height: pageHeight, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: width, height: pageHeight,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue) {
            Self.drawCode(in: context, width: width, height: pageHeight)
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        page = try Self.buffer(width: width, height: pageHeight, format: nv12)
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let transfer = created else { throw XCTSkip("no pixel transfer session") }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard VTPixelTransferSessionTransferImage(transfer, from: bgra, to: page) == noErr else {
            throw XCTSkip("pixel transfer failed")
        }
        ring = try (0..<4).map { _ in try Self.buffer(width: width, height: height, format: nv12) }
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
            let first = plane == 0 ? offset : offset / 2
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                memcpy(to + row * toStride, from + (first + row) * fromStride, min(fromStride, toStride))
            }
        }
        return buffer
    }

    private static func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                  .shouldPropagate)
        }
        return buffer
    }

    /// Editor-like text in two panes with coloured comments and a selection band every 11 lines; the context is
    /// flipped here so rows run top to bottom.
    private static func drawCode(in context: CGContext, width: Int, height: Int) {
        let lines = ["func configureNativeSender(quality: StreamQuality) -> RTCRtpParameters {",
                     "    let parameters = sender.parameters // max 20_000_000 bps, start 8_000_000",
                     "    guard let encoding = parameters.encodings.first else { return parameters }",
                     "error: cannot convert value of type '[String: Any]' to expected argument type 'Int32'",
                     "  0x00007ff8 in PeerMedia.publishStreamStatistics(_:) + 412 at PeerMedia.swift:233",
                     "    // HEVC Main 4:2:0 at 2560x1656, 120 fps, one frame in flight",
                     "}"]
        let space = CGColorSpaceCreateDeviceRGB()
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let font = CTFontCreateWithName("Menlo" as CFString, 22, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colourKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let plain = colour(0.1, 0.1, 0.1), comment = colour(0, 0.45, 0), keyword = colour(0.61, 0.14, 0.58)
        let lineHeight = 30, pane = width / 2
        for row in 0..<(height / lineHeight + 1) {
            if row % 11 == 5 {
                context.setFillColor(colour(0.8, 0.88, 1))
                context.fill(CGRect(x: 0, y: row * lineHeight, width: width, height: lineHeight))
            }
            for column in 0..<2 {
                let text = String(format: "%4d  ", row + 1) + lines[(row + column * 3) % lines.count]
                let attributed = NSMutableAttributedString(string: text, attributes: [fontKey: font, colourKey: plain])
                let whole = text as NSString
                let slashes = whole.range(of: "//")
                if slashes.location != NSNotFound {
                    attributed.addAttribute(colourKey, value: comment,
                                            range: NSRange(location: slashes.location,
                                                           length: whole.length - slashes.location))
                }
                for word in ["func ", "let ", "guard ", "return "] {
                    let range = whole.range(of: word)
                    if range.location != NSNotFound { attributed.addAttribute(colourKey, value: keyword, range: range) }
                }
                context.textPosition = CGPoint(x: CGFloat(column * pane + 8), y: CGFloat(row * lineHeight + 22))
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
    }
}
