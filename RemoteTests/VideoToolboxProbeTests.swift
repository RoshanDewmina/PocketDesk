import XCTest
import CoreText
import CoreVideo
import VideoToolbox

/// Opt-in: encodes a rendered code page directly with VideoToolbox under several rate-control
/// configurations and reports bytes, encode latency and decoded luma PSNR. It isolates the encoder
/// from WebRTC pacing and bandwidth estimation.
/// Run: POCKETDESK_VT_PROBE=1 xcrun xctest -XCTest RemoteCoreTests.VideoToolboxProbeTests <bundle>
final class VideoToolboxProbeTests: XCTestCase {
    private struct Configuration {
        var name: String
        var lowLatency = false
        var dataRateLimits = true
        var bitrate = 18_000_000
    }

    func testRateControlConfigurations() throws {
        guard ProcessInfo.processInfo.environment["POCKETDESK_VT_PROBE"] == "1" else {
            throw XCTSkip("Set POCKETDESK_VT_PROBE=1 to probe VideoToolbox rate control.")
        }
        let width = 2560, height = 1664
        let source = try Self.textFrame(width: width, height: height, shift: 0)
        let scrolled = try (1...30).map { try Self.textFrame(width: width, height: height, shift: $0 * 12) }
        let configurations = [
            Configuration(name: "stock-like 18M"),
            Configuration(name: "stock-like 18M no DataRateLimits", dataRateLimits: false),
            Configuration(name: "stock-like 5M", bitrate: 5_000_000),
            Configuration(name: "stock-like 0.3M (libwebrtc start rate)", bitrate: 300_000),
            Configuration(name: "low-latency 18M", lowLatency: true),
            Configuration(name: "low-latency 5M", lowLatency: true, bitrate: 5_000_000),
        ]
        for configuration in configurations {
            let result = try encode(configuration, first: source, then: scrolled, width: width, height: height)
            print("VT PROBE \(configuration.name): created=\(result.created) hw=\(result.hardware) " +
                  "key=\(result.keyBytes)B keyPSNR=\(String(format: "%.2f", result.keyPSNR)) " +
                  "scrollAvg=\(result.scrollAverageBytes)B scrollPSNR=\(String(format: "%.2f", result.scrollPSNR)) " +
                  "encodeMs p50=\(String(format: "%.1f", result.encodeP50)) max=\(String(format: "%.1f", result.encodeMax))")
        }
    }

    /// Mirrors libwebrtc's session history: key frame at the 300 kb/s start rate, a static second,
    /// then an 18 Mb/s target. Measures how good a forced key frame is right after the rise and later.
    func testKeyFrameQualityAfterRateRise() throws {
        guard ProcessInfo.processInfo.environment["POCKETDESK_VT_PROBE"] == "1" else {
            throw XCTSkip("Set POCKETDESK_VT_PROBE=1 to probe VideoToolbox rate control.")
        }
        let page = try Self.textFrame(width: 2560, height: 1664, shift: 0)
        // 1.5x/1 s matches the older libwebrtc wrapper in the shipped binary; -10 is newer upstream's
        // 10x peak per second plus the average over 5 s; 0 sets no limit.
        for limitFactor in [1.5, 4, -10, 0] {
            var optionalSession: VTCompressionSession?
            let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
            guard VTCompressionSessionCreate(allocator: nil, width: 2560, height: 1664, codecType: kCMVideoCodecType_H264,
                                             encoderSpecification: specification, imageBufferAttributes: nil,
                                             compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                             compressionSessionOut: &optionalSession) == noErr,
                  let session = optionalSession else { continue }
            defer { VTCompressionSessionInvalidate(session) }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
            func setRate(_ bps: Int) {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
                if limitFactor > 0 {
                    let limits = [Int(Double(bps) * limitFactor / 8), 1.0] as [Any]
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
                } else if limitFactor < 0 {
                    let limits = [Int(Double(bps) * -limitFactor / 8), 1.0, bps / 8 * 5, 5.0] as [Any]
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
                }
            }
            var decoder: VTDecompressionSession?
            defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
            var pts: CMTimeValue = 0
            func encode(key: Bool, measure: Bool) -> String {
                var encoded: CMSampleBuffer?
                let done = DispatchSemaphore(value: 0)
                let properties = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
                VTCompressionSessionEncodeFrame(session, imageBuffer: page, presentationTimeStamp: CMTime(value: pts, timescale: 60),
                                                duration: CMTime(value: 1, timescale: 60), frameProperties: properties,
                                                infoFlagsOut: nil) { status, _, sample in
                    if status == noErr { encoded = sample }
                    done.signal()
                }
                done.wait()
                pts += 1
                guard let encoded, let data = CMSampleBufferGetDataBuffer(encoded) else { return "dropped" }
                if decoder == nil, let format = CMSampleBufferGetFormatDescription(encoded) {
                    VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                 imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
                }
                var psnr = 0.0
                if let decoder {
                    VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: encoded, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
                        if measure, let image { psnr = Self.psnr(image, page) }
                    }
                }
                return "\(CMBlockBufferGetDataLength(data) / 1024)KB \(String(format: "%.1f", psnr))dB"
            }
            setRate(300_000)
            VTCompressionSessionPrepareToEncodeFrames(session)
            let start = encode(key: true, measure: true)
            for _ in 0..<60 { _ = encode(key: false, measure: false) }
            let staticAfterStart = encode(key: false, measure: true)
            setRate(18_000_000)
            let immediate = encode(key: true, measure: true)
            for _ in 0..<60 { _ = encode(key: false, measure: false) }
            let oneSecond = encode(key: true, measure: true)
            for _ in 0..<120 { _ = encode(key: false, measure: false) }
            let threeSeconds = encode(key: true, measure: true)
            let staticAfter = encode(key: false, measure: true)
            let label = limitFactor == 0 ? "none" : limitFactor < 0 ? "\(-limitFactor)x/1s+avg/5s" : "\(limitFactor)x/1s"
            print("VT RISE limits=\(label): key@0.3M \(start) · static@0.3M \(staticAfterStart) · " +
                  "key right after rise to 18M \(immediate) · key +1s \(oneSecond) · key +3s \(threeSeconds) · static after \(staticAfter)")
        }
    }

    private struct Result {
        var created = false
        var hardware = "?"
        var keyBytes = 0
        var keyPSNR = 0.0
        var scrollAverageBytes = 0
        var scrollPSNR = 0.0
        var encodeP50 = 0.0
        var encodeMax = 0.0
    }

    private func encode(_ configuration: Configuration, first: CVPixelBuffer, then frames: [CVPixelBuffer],
                        width: Int, height: Int) throws -> Result {
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if configuration.lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var optionalSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &optionalSession)
        guard status == noErr, let session = optionalSession else { return Result() }
        defer { VTCompressionSessionInvalidate(session) }
        var result = Result(created: true)
        var usingHardware: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &usingHardware) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        result.hardware = hardwareStatus == noErr ? String(describing: (usingHardware as? Bool) ?? false) : "unreported(\(hardwareStatus))"
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: configuration.bitrate as CFNumber)
        if configuration.dataRateLimits {
            let limits = [configuration.bitrate * 10 / 8, 1.0, configuration.bitrate / 8 * 5, 5.0] as [Any]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        var decoder: VTDecompressionSession?
        defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
        var timings: [Double] = []
        var scrollBytes = 0, scrollPSNRs: [Double] = []
        for (index, frame) in ([first] + frames).enumerated() {
            let started = CACurrentMediaTime()
            var encoded: CMSampleBuffer?
            let done = DispatchSemaphore(value: 0)
            let properties = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: frame,
                                            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                                            duration: CMTime(value: 1, timescale: 60), frameProperties: properties,
                                            infoFlagsOut: nil) { status, _, sample in
                if status == noErr { encoded = sample }
                done.signal()
            }
            done.wait()
            timings.append((CACurrentMediaTime() - started) * 1000)
            guard let encoded, let data = CMSampleBufferGetDataBuffer(encoded) else { continue }
            let bytes = CMBlockBufferGetDataLength(data)
            if decoder == nil, let format = CMSampleBufferGetFormatDescription(encoded) {
                VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil,
                                             decompressionSessionOut: &decoder)
            }
            var psnr = 0.0
            if let decoder {
                VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: encoded, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
                    if let image { psnr = Self.psnr(image, frame) }
                }
            }
            if index == 0 { result.keyBytes = bytes; result.keyPSNR = psnr }
            else { scrollBytes += bytes; scrollPSNRs.append(psnr) }
        }
        let sorted = timings.sorted()
        result.encodeP50 = sorted[sorted.count / 2]
        result.encodeMax = sorted.last ?? 0
        result.scrollAverageBytes = scrollBytes / max(1, frames.count)
        result.scrollPSNR = scrollPSNRs.isEmpty ? 0 : scrollPSNRs.reduce(0, +) / Double(scrollPSNRs.count)
        return result
    }

    private static func psnr(_ decoded: CVPixelBuffer, _ source: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(decoded, .readOnly); CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddressOfPlane(source, 0)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let expand = CVPixelBufferGetPixelFormatType(decoded) != CVPixelBufferGetPixelFormatType(source)
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0), strideB = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        var squared = 0.0, count = 0.0
        for y in stride(from: 0, to: CVPixelBufferGetHeight(source), by: 2) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(source), by: 2) {
                let expected = expand ? (Double(b[y * strideB + x]) - 16) * 255 / 219 : Double(b[y * strideB + x])
                let diff = Double(a[y * strideA + x]) - expected
                squared += diff * diff; count += 1
            }
        }
        let mse = squared / max(1, count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    private static func textFrame(width: Int, height: Int, shift: Int) throws -> CVPixelBuffer {
        var gray = [UInt8](repeating: 255, count: width * height)
        let lines = ["func configureNativeSender(quality: StreamQuality) -> RTCRtpParameters {",
                     "    let parameters = sender.parameters // max 20_000_000 bps, start 8_000_000",
                     "error: cannot convert value of type '[String: Any]' to expected argument type 'Int32'",
                     "  0x00007ff8 in PeerMedia.publishStreamStatistics(_:) + 412 at PeerMedia.swift:233"]
        gray.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            var row = 0
            var y = Double(height) - 34 + Double(shift)
            while y > -34 {
                if y < Double(height) {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: lines[row % lines.count], attributes: attributes))
                    for column in stride(from: 0, to: width, by: 1300) {
                        context.textPosition = CGPoint(x: Double(column) + 24, y: y)
                        CTLineDraw(line, context)
                    }
                }
                row += 1; y -= 34
            }
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height { for x in 0..<width { luma[y * stride + x] = UInt8(16 + (Int(gray[y * width + x]) * 219 + 127) / 255) } }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<(height / 2) { memset(chroma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), 128, width) }
        return buffer
    }
}
