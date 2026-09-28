import Foundation
import CoreVideo
import VideoToolbox
import CoreGraphics
import CoreText
import CoreMedia
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func nowMS() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
func cpuTime() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6 + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6 }
let fullMotion = ProcessInfo.processInfo.environment["FULLMOTION"] == "1"
let targetFmt: OSType = ProcessInfo.processInfo.environment["PIXFMT"] == "444v" ? 0x34343476 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange


func pixelBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let st = CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb)
    precondition(st == kCVReturnSuccess, "CVPixelBufferCreate \(st)")
    return pb!
}

let codeLines = [
    "func encode(frame: CVPixelBuffer, at time: CMTime) throws -> EncodedFrame {",
    "    let started = CACurrentMediaTime()   // Il1| O0 rn m {}[]()<>",
    "    guard let session = compression else { throw StreamError.noSession }",
    "    var flags = VTEncodeInfoFlags(); let props = needsKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil",
    "    let status = VTCompressionSessionEncodeFrame(session, imageBuffer: frame, presentationTimeStamp: time,",
    "        duration: .invalid, frameProperties: props as CFDictionary?, infoFlagsOut: &flags) { s, f, sample in",
    "        guard s == noErr, let sample else { return }",
    "        self.queue.async { self.send(sample, latency: CACurrentMediaTime() - started) }",
    "    }",
    "    if status != noErr { throw StreamError.encode(status) }",
    "}",
]

func drawFrame(_ w: Int, _ h: Int, _ index: Int) -> CVPixelBuffer {
    let bgra = pixelBuffer(w, h, kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(bgra, [])
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let scale = CGFloat(w) / 1470.0
    let fontSize = 13 * scale
    let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
    func text(_ s: String, x: CGFloat, y: CGFloat, color: CGColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
    let black = CGColor(gray: 0.08, alpha: 1)
    let blue = CGColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1)
    let red = CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
    let green = CGColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 1)
    let colors = [black, blue, red, green]
    let lineH = fontSize * 1.5
    let leftW = CGFloat(w) * 0.55
    _ = leftW
    var y = CGFloat(h) - 60 * scale + (fullMotion ? CGFloat(index) * 7 * scale : 0)
    for row in 0..<Int((CGFloat(h) - 200 * scale) / lineH) + (fullMotion ? 12 : 0) {
        let s = codeLines[row % codeLines.count]
        text(s, x: 30 * scale, y: y, color: colors[(row / 3) % colors.count])
        y -= lineH
    }
    // scrolling pane on the right
    let paneX = CGFloat(w) * 0.6
    ctx.saveGState()
    ctx.clip(to: CGRect(x: paneX, y: 40 * scale, width: CGFloat(w) * 0.37, height: CGFloat(h) - 200 * scale))
    var sy = CGFloat(h) - 80 * scale + CGFloat(index) * 5 * scale
    for row in 0..<200 {
        text("\(row + index / 3) " + codeLines[(row + index / 3) % codeLines.count], x: paneX + 10 * scale, y: sy, color: black)
        sy -= lineH
    }
    ctx.restoreGState()
    // moving block
    let bx = CGFloat((index * 24) % (w - 200))
    ctx.setFillColor(CGColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 1))
    ctx.fill(CGRect(x: bx, y: CGFloat(h) * 0.5, width: 70 * scale, height: 70 * scale))
    // blinking caret
    if (index / 15) % 2 == 0 {
        ctx.setFillColor(black)
        ctx.fill(CGRect(x: 30 * scale + 200 * scale, y: CGFloat(h) - 60 * scale - lineH * 4 - 3 * scale, width: 2 * scale, height: fontSize * 1.2))
    }
    CVPixelBufferUnlockBaseAddress(bgra, [])
    let nv12 = pixelBuffer(w, h, targetFmt)
    for (k, v) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                   (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                   (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
        CVBufferSetAttachment(nv12, k, v, .shouldPropagate)
    }
    var pts: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &pts)
    VTPixelTransferSessionTransferImage(pts!, from: bgra, to: nv12)
    VTPixelTransferSessionInvalidate(pts!)
    return nv12
}

func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer, plane: Int, xRange: Range<Double>) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(a, plane), h = CVPixelBufferGetHeightOfPlane(a, plane)
    let sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
    let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt8.self)
    let x0 = Int(Double(w) * xRange.lowerBound), x1 = Int(Double(w) * xRange.upperBound)
    let ch = plane == 0 ? 1 : 2
    var se = 0.0, n = 0.0
    var y = 0
    while y < h {
        let ra = pa + y * sa, rb = pb + y * sb
        var x = x0 * ch
        let end = x1 * ch
        while x < end { let d = Double(Int(ra[x]) - Int(rb[x])); se += d * d; x += 1 }
        n += Double(end - x0 * ch)
        y += 2
    }
    let mse = se / max(n, 1)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

struct Cfg {
    let name: String
    let codec: CMVideoCodecType
    let lowLatency: Bool
    let realtime: Bool
    let prioritizeSpeed: Bool?
    let profile: CFString?
    let bitrate: Int
    let dataRateLimits: Bool
    var quality: Float? = nil
    var maxQP: Int? = nil
}

final class Collector {
    var lock = NSLock()
    var latencies: [Double] = []
    var sizes: [Int] = []
    var keys: [Bool] = []
    var samples: [(Int, CMSampleBuffer)] = []
    var submitAt: [Int: Double] = [:]
    var dropped = 0
}

func str4(_ f: OSType) -> String { String(bytes: [UInt8((f >> 24) & 255), UInt8((f >> 16) & 255), UInt8((f >> 8) & 255), UInt8(f & 255)], encoding: .ascii) ?? "?" }
func propStatus(_ s: OSStatus) -> String { s == noErr ? "ok" : "\(s)" }

func runConfig(_ cfg: Cfg, w: Int, h: Int, frames: [CVPixelBuffer], count: Int, paced: Bool) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
    if cfg.lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var session: VTCompressionSession?
    let src: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: targetFmt,
                                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                kCVPixelBufferIOSurfacePropertiesKey: [:]]
    let col = Collector()
    let cst = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: cfg.codec,
                                         encoderSpecification: spec as CFDictionary, imageBufferAttributes: src as CFDictionary,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard cst == noErr, let session else { print("  [\(cfg.name)] create failed \(cst)"); return }
    var notes: [String] = []
    func set(_ key: CFString, _ v: CFTypeRef, _ label: String) {
        let s = VTSessionSetProperty(session, key: key, value: v)
        if s != noErr { notes.append("\(label)=\(s)") }
    }
    if cfg.realtime { set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime") } else { set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse, "RealTime") }
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "Reorder")
    if let p = cfg.prioritizeSpeed { set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, p as CFBoolean, "PrioSpeed") }
    if let p = cfg.profile { set(kVTCompressionPropertyKey_ProfileLevel, p, "Profile") }
    set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber, "FPS")
    set(kVTCompressionPropertyKey_AverageBitRate, cfg.bitrate as CFNumber, "AvgBitRate")
    if cfg.dataRateLimits {
        let limits: [NSNumber] = [NSNumber(value: cfg.bitrate * 10 / 8), 1.0, NSNumber(value: cfg.bitrate / 8 * 5), 5.0]
        set(kVTCompressionPropertyKey_DataRateLimits, limits as CFArray, "DataRateLimits")
    }
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber, "MaxKF")
    if let q = cfg.quality { set(kVTCompressionPropertyKey_Quality, q as CFNumber, "Quality") }
    if let q = cfg.maxQP { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, q as CFNumber, "MaxQP") }
    VTCompressionSessionPrepareToEncodeFrames(session)
    var hw: CFTypeRef?
    _ = withUnsafeMutablePointer(to: &hw) { VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0) }
    var delay: CFTypeRef?
    _ = withUnsafeMutablePointer(to: &delay) { VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, allocator: nil, valueOut: $0) }
    let start = nowMS()
    let cpu0 = cpuTime()
    for i in 0..<count {
        if paced { let target = start + Double(i) * 1000.0 / 60.0; while nowMS() < target { usleep(200) } }
        let t0 = nowMS()
        col.lock.lock(); col.submitAt[i] = t0; col.lock.unlock()
        let props: CFDictionary? = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: frames[i % frames.count],
                                                 presentationTimeStamp: CMTime(value: Int64(i), timescale: 60),
                                                 duration: CMTime(value: 1, timescale: 60), frameProperties: props, infoFlagsOut: nil) { status, flags, sbuf in
            let t1 = nowMS()
            col.lock.lock(); defer { col.lock.unlock() }
            guard status == noErr, let sbuf else { col.dropped += 1; return }
            let pts = Int(CMSampleBufferGetPresentationTimeStamp(sbuf).value)
            if let s = col.submitAt[pts] { col.latencies.append(t1 - s) }
            col.sizes.append(CMSampleBufferGetTotalSampleSize(sbuf))
            let att = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            col.keys.append(!notSync)
            col.samples.append((pts, sbuf))
        }
        if st != noErr { col.dropped += 1 }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let wall = nowMS() - start
    let cpuUsed = cpuTime() - cpu0
    VTCompressionSessionInvalidate(session)
    col.lock.lock()
    let lat = col.latencies.sorted()
    func pct(_ p: Double) -> Double { lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * p))] }
    let total = col.sizes.reduce(0, +)
    let inter = zip(col.sizes, col.keys).filter { !$0.1 }.map { $0.0 }
    let keysz = zip(col.sizes, col.keys).filter { $0.1 }.map { $0.0 }
    let mbps = Double(total) * 8 / (Double(col.sizes.count) / 60.0) / 1e6
    let samples = col.samples.sorted { $0.0 < $1.0 }
    col.lock.unlock()
    let hwStr = (hw as? Bool).map { $0 ? "HW" : "SW" } ?? "?"
    print(String(format: "  [%@] %@ n=%d drop=%d enc-latency ms p50=%.1f p95=%.1f max=%.1f | throughput=%.0f fps | %.2f Mb/s@60 | inter avg %.0f B, key avg %.0f B | delayCount=%@ %@",
                 cfg.name, hwStr, lat.count, col.dropped, pct(0.5), pct(0.95), lat.last ?? 0, Double(col.sizes.count) / (wall / 1000),
                 mbps, inter.isEmpty ? 0 : Double(inter.reduce(0, +)) / Double(inter.count), keysz.isEmpty ? 0 : Double(keysz.reduce(0, +)) / Double(keysz.count),
                 (delay as? NSNumber)?.stringValue ?? "?", notes.isEmpty ? "" : "notUsed: " + notes.joined(separator: ",")))
    print(String(format: "    cpu: %.2f s over %.2f s wall = %.0f%% of one core", cpuUsed, wall / 1000, cpuUsed / (wall / 1000) * 100))
    // decode + psnr
    guard let first = samples.first, let fmt = CMSampleBufferGetFormatDescription(first.1) else { return }
    var dec: VTDecompressionSession?
    let dattrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: targetFmt, kCVPixelBufferMetalCompatibilityKey: true]
    let dst = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: dattrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &dec)
    guard dst == noErr, let dec else { print("    decode create failed \(dst)"); return }
    VTSessionSetProperty(dec, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var lumaAll: [Double] = [], lumaText: [Double] = [], chroma: [Double] = [], decMS: [Double] = []
    let dlock = NSLock()
    for (idx, s) in samples.enumerated() {
        let d0 = nowMS()
        VTDecompressionSessionDecodeFrame(dec, sampleBuffer: s.1, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            guard status == noErr, let img else { return }
            let d1 = nowMS()
            dlock.lock(); decMS.append(d1 - d0); dlock.unlock()
            if idx % 6 == 0 {
                let ref = frames[s.0 % frames.count]
                let a = psnr(ref, img, plane: 0, xRange: 0.0..<1.0)
                let t = psnr(ref, img, plane: 0, xRange: 0.0..<0.55)
                let c = psnr(ref, img, plane: 1, xRange: 0.0..<0.55)
                dlock.lock(); lumaAll.append(a); lumaText.append(t); chroma.append(c); dlock.unlock()
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(dec)
    }
    VTDecompressionSessionInvalidate(dec)
    func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    func mn(_ a: [Double]) -> Double { a.min() ?? 0 }
    let ds = decMS.sorted()
    print(String(format: "    quality: luma PSNR all avg %.1f dB (min %.1f) | text-region avg %.1f dB (min %.1f) | chroma(text) avg %.1f dB | Mac decode-latency p50 %.1f ms p95 %.1f ms",
                 avg(lumaAll), mn(lumaAll), avg(lumaText), mn(lumaText), avg(chroma), ds.isEmpty ? 0 : ds[ds.count / 2], ds.isEmpty ? 0 : ds[min(ds.count - 1, Int(Double(ds.count) * 0.95))]))
}

// ---------- environment probes ----------
print("== Encoder list (H.264/HEVC) ==")
var listRef: CFArray?
VTCopyVideoEncoderList(nil, &listRef)
for e in (listRef as? [[String: Any]] ?? []) {
    let codec = e["CodecType"] as? UInt32 ?? 0
    let cs = String(bytes: [UInt8((codec >> 24) & 255), UInt8((codec >> 16) & 255), UInt8((codec >> 8) & 255), UInt8(codec & 255)], encoding: .ascii) ?? "?"
    guard ["avc1", "hvc1"].contains(cs) else { continue }
    print("  ", cs, e["EncoderID"] ?? "", "hw=\(e["HardwareAccelerated"] ?? "?")", e["DisplayName"] ?? "")
}

func supportedProps(_ codec: CMVideoCodecType, _ w: Int, _ h: Int, ll: Bool) -> [String] {
    var id: CFString?
    var dict: CFDictionary?
    let spec: [CFString: Any] = ll ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] : [:]
    let st = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: spec as CFDictionary, encoderIDOut: &id, supportedPropertiesOut: &dict)
    guard st == noErr, let d = dict as? [String: Any] else { return ["status \(st)"] }
    return d.keys.sorted()
}

let W = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 2940
let H = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 1912
let mode = CommandLine.arguments.dropFirst(3).first ?? "all"

if mode == "props" || mode == "all" {
    for (n, c) in [("H264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC)] {
        for ll in [false, true] {
            let p = supportedProps(c, W, H, ll: ll)
            print("== \(n) lowLatencyRC=\(ll) supported props (\(p.count)) ==")
            let interesting = p.filter { k in ["MaxFrameDelayCount", "PrioritizeEncodingSpeedOverQuality", "MaxAllowedFrameQP", "MinAllowedFrameQP", "Quality", "EnableLTR", "SpatialAdaptiveQPLevel", "ReferenceBufferCount", "BaseLayerFrameRateFraction", "ConstantBitRate", "MaxH264SliceBytes", "DataRateLimits", "AverageBitRate", "ProfileLevel", "MaxKeyFrameInterval", "AllowOpenGOP", "SupportedPresetDictionaries", "ConstantQualityFactor", "EntropyMode", "H264EntropyMode", "VariableBitRate", "MaximizePowerEfficiency", "AllowTemporalCompression", "PixelTransferProperties", "SourcePixelBufferAttributes", "MinimizeMemoryUsage", "SuggestedLookAheadFrameCount", "ExpectedDuration", "Depth", "Slice"].contains(where: { k.contains($0) }) }
            print("   ", interesting.joined(separator: ", "))
        }
    }
}

func tryCreate(_ label: String, codec: CMVideoCodecType, fmt: OSType, profile: CFString?, ll: Bool, w: Int = 1920, h: Int = 1080) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if ll { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    let src: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: fmt, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h]
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: src as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    var out = "create=\(st)"
    if st == noErr, let s {
        if let profile { out += " profile=\(propStatus(VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)))" }
        out += " prepare=\(VTCompressionSessionPrepareToEncodeFrames(s))"
        VTCompressionSessionInvalidate(s)
    }
    print("  \(label): \(out)")
}

if mode == "formats" || mode == "all" {
    print("== Hardware-required session creation probes (1920x1080) ==")
    let fourcc: (String) -> OSType = { $0.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
    tryCreate("H264 High 420v LL", codec: kCMVideoCodecType_H264, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_H264_High_AutoLevel, ll: true)
    tryCreate("H264 High 420v noLL", codec: kCMVideoCodecType_H264, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_H264_High_AutoLevel, ll: false)
    tryCreate("H264 Main 420v LL (header says High-only)", codec: kCMVideoCodecType_H264, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_H264_Main_AutoLevel, ll: true)
    tryCreate("H264 Baseline 420v LL", codec: kCMVideoCodecType_H264, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_H264_Baseline_AutoLevel, ll: true)
    tryCreate("HEVC Main 420v LL", codec: kCMVideoCodecType_HEVC, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_HEVC_Main_AutoLevel, ll: true)
    tryCreate("HEVC Main 420v noLL", codec: kCMVideoCodecType_HEVC, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_HEVC_Main_AutoLevel, ll: false)
    tryCreate("HEVC Main10 x420 noLL", codec: kCMVideoCodecType_HEVC, fmt: fourcc("x420"), profile: kVTProfileLevel_HEVC_Main10_AutoLevel, ll: false)
    tryCreate("HEVC Main10 x420 LL", codec: kCMVideoCodecType_HEVC, fmt: fourcc("x420"), profile: kVTProfileLevel_HEVC_Main10_AutoLevel, ll: true)
    tryCreate("HEVC Main42210 x422 noLL", codec: kCMVideoCodecType_HEVC, fmt: fourcc("x422"), profile: kVTProfileLevel_HEVC_Main42210_AutoLevel, ll: false)
    tryCreate("HEVC 4:4:4 8-bit (444v) noLL", codec: kCMVideoCodecType_HEVC, fmt: fourcc("444v"), profile: nil, ll: false)
    tryCreate("HEVC 4:4:4 10-bit xf44 noLL", codec: kCMVideoCodecType_HEVC, fmt: fourcc("xf44"), profile: nil, ll: false)
    tryCreate("HEVC 4:4:4 BGRA noLL (VT converts?)", codec: kCMVideoCodecType_HEVC, fmt: kCVPixelFormatType_32BGRA, profile: nil, ll: false)
    tryCreate("H264 4:4:4 (444v) noLL", codec: kCMVideoCodecType_H264, fmt: fourcc("444v"), profile: nil, ll: false)
    tryCreate("AV1 420v", codec: kCMVideoCodecType_AV1, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: nil, ll: false)
    print("VTIsHardwareDecodeSupported: H264=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) HEVC=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) AV1=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
}

if mode == "bench444" {
    print("== 4:4:4 HEVC RExt (hardware) \(W)x\(H); PIXFMT=\(str4(targetFmt)) ==")
    let frames = (0..<24).map { drawFrame(W, H, $0) }
    for br in [12_000_000, 25_000_000, 40_000_000] {
        runConfig(Cfg(name: "HEVC RExt 4:4:4 RT no-LL \(br/1_000_000)M", codec: kCMVideoCodecType_HEVC, lowLatency: false, realtime: true, prioritizeSpeed: nil, profile: nil, bitrate: br, dataRateLimits: false), w: W, h: H, frames: frames, count: 240, paced: true)
    }
    runConfig(Cfg(name: "HEVC RExt 4:4:4 RT no-LL 25M unpaced", codec: kCMVideoCodecType_HEVC, lowLatency: false, realtime: true, prioritizeSpeed: nil, profile: nil, bitrate: 25_000_000, dataRateLimits: false), w: W, h: H, frames: frames, count: 240, paced: false)
}
if mode == "bench" || mode == "all" {
    print("== Rendering \(W)x\(H) synthetic desktop frames (text + scroll + moving block) ==")
    let frames = (0..<24).map { drawFrame(W, H, $0) }
    let count = 240
    let hi = kVTProfileLevel_H264_High_AutoLevel
    let cfgs: [Cfg] = [
        Cfg(name: "H264 High, WebRTC-like (RT, no LL, avg+limits) 12M", codec: kCMVideoCodecType_H264, lowLatency: false, realtime: true, prioritizeSpeed: nil, profile: hi, bitrate: 12_000_000, dataRateLimits: true),
        Cfg(name: "H264 High, LL-RC + RT + PrioSpeed 12M", codec: kCMVideoCodecType_H264, lowLatency: true, realtime: true, prioritizeSpeed: true, profile: hi, bitrate: 12_000_000, dataRateLimits: false),
        Cfg(name: "H264 High, LL-RC + RT (no PrioSpeed) 12M", codec: kCMVideoCodecType_H264, lowLatency: true, realtime: true, prioritizeSpeed: nil, profile: hi, bitrate: 12_000_000, dataRateLimits: false),
        Cfg(name: "H264 High, LL-RC + RT + PrioSpeed 30M", codec: kCMVideoCodecType_H264, lowLatency: true, realtime: true, prioritizeSpeed: true, profile: hi, bitrate: 30_000_000, dataRateLimits: false),
        Cfg(name: "H264 High, LL-RC + RT + PrioSpeed 5M", codec: kCMVideoCodecType_H264, lowLatency: true, realtime: true, prioritizeSpeed: true, profile: hi, bitrate: 5_000_000, dataRateLimits: false),
        Cfg(name: "HEVC Main, LL-RC + RT + PrioSpeed 12M", codec: kCMVideoCodecType_HEVC, lowLatency: true, realtime: true, prioritizeSpeed: true, profile: kVTProfileLevel_HEVC_Main_AutoLevel, bitrate: 12_000_000, dataRateLimits: false),
        Cfg(name: "HEVC Main, RT no-LL 12M", codec: kCMVideoCodecType_HEVC, lowLatency: false, realtime: true, prioritizeSpeed: nil, profile: kVTProfileLevel_HEVC_Main_AutoLevel, bitrate: 12_000_000, dataRateLimits: false),
        Cfg(name: "HEVC Main, LL-RC + RT + PrioSpeed 5M", codec: kCMVideoCodecType_HEVC, lowLatency: true, realtime: true, prioritizeSpeed: true, profile: kVTProfileLevel_HEVC_Main_AutoLevel, bitrate: 5_000_000, dataRateLimits: false),
    ]
    for cfg in cfgs { runConfig(cfg, w: W, h: H, frames: frames, count: count, paced: true) }
    print("-- unpaced throughput (encoder back-to-back), H264 LL vs HEVC LL --")
    runConfig(cfgs[1], w: W, h: H, frames: frames, count: count, paced: false)
    runConfig(cfgs[5], w: W, h: H, frames: frames, count: count, paced: false)
}
