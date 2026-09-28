import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import AppKit
import VideoToolbox
import WebRTC

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let width = Int(env["W"] ?? "") ?? 1920
let height = Int(env["H"] ?? "") ?? 1248
let seconds = Double(env["SECONDS"] ?? "") ?? 14
let content = env["CONTENT"] ?? "desktop"
let label = env["LABEL"] ?? "run"

if let trials = env["TRIALS"], !trials.isEmpty {
    var dict: [String: String] = [:]
    for item in trials.split(separator: ";") {
        let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { dict[parts[0]] = parts[1] }
    }
    RTCInitFieldTrialDictionary(dict)
    print("field trials set: \(dict)")
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
func pixelBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    precondition(CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    return pb!
}
func drawFrame(_ w: Int, _ h: Int, _ index: Int, motion: Bool) -> CVPixelBuffer {
    let bgra = pixelBuffer(w, h, kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(bgra, [])
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let scale = CGFloat(w) / 1470.0
    let font = CTFontCreateWithName("Menlo" as CFString, 13 * scale, nil)
    func text(_ s: String, x: CGFloat, y: CGFloat, color: CGColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
    }
    let colors = [CGColor(gray: 0.08, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1), CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 1)]
    let lineH = 13 * scale * 1.5
    var y = CGFloat(h) - 60 * scale + (motion ? CGFloat(index) * 7 * scale : 0)
    for row in 0..<Int((CGFloat(h) - 200 * scale) / lineH) + (motion ? 12 : 0) { text(codeLines[row % codeLines.count], x: 30 * scale, y: y, color: colors[(row / 3) % 4]); y -= lineH }
    let paneX = CGFloat(w) * 0.6
    ctx.saveGState(); ctx.clip(to: CGRect(x: paneX, y: 40 * scale, width: CGFloat(w) * 0.37, height: CGFloat(h) - 200 * scale))
    var sy = CGFloat(h) - 80 * scale + CGFloat(index) * 5 * scale
    for row in 0..<200 { text("\(row + index / 3) " + codeLines[(row + index / 3) % codeLines.count], x: paneX + 10 * scale, y: sy, color: colors[0]); sy -= lineH }
    ctx.restoreGState()
    ctx.setFillColor(CGColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 1)); ctx.fill(CGRect(x: CGFloat((index * 24) % (w - 200)), y: CGFloat(h) * 0.5, width: 70 * scale, height: 70 * scale))
    CVPixelBufferUnlockBaseAddress(bgra, [])
    let nv12 = pixelBuffer(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    for (k, v) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2), (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2), (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] { CVBufferSetAttachment(nv12, k, v, .shouldPropagate) }
    var pts: VTPixelTransferSession?; VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &pts)
    VTPixelTransferSessionTransferImage(pts!, from: bgra, to: nv12); VTPixelTransferSessionInvalidate(pts!)
    CVPixelBufferLockBaseAddress(nv12, [])
    let ls = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0), cstride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1)
    let lp = CVPixelBufferGetBaseAddressOfPlane(nv12, 0)!.assumingMemoryBound(to: UInt8.self)
    let cp = CVPixelBufferGetBaseAddressOfPlane(nv12, 1)!.assumingMemoryBound(to: UInt8.self)
    for bit in 0..<6 {
        let on = (index >> bit) & 1 == 1
        for yy in 0..<48 { for xx in (bit * 48)..<((bit + 1) * 48) { lp[yy * ls + xx] = on ? 235 : 16 } }
        for yy in 0..<24 { for xx in (bit * 24)..<((bit + 1) * 24) { cp[yy * cstride + xx * 2] = 128; cp[yy * cstride + xx * 2 + 1] = 128 } }
    }
    CVPixelBufferUnlockBaseAddress(nv12, [])
    return nv12
}

final class LatencyProbe: NSObject, RTCVideoRenderer {
    let lock = NSLock()
    var pushTimes = [Double](repeating: 0, count: 64)
    var latencies: [Double] = []
    var lastSlot = -1
    var repeats = 0
    var psnrs: [Double] = []
    var psnrsText: [Double] = []
    var frameCount = 0
    var latSeries: [(Double, Double)] = []
    var psnrSeries: [(Double, Double)] = []
    var source: [CVPixelBuffer] = []
    var startedAt = 0.0
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buf = frame.buffer as? RTCCVPixelBuffer else { return }
        let pb = buf.pixelBuffer
        let now = ProcessInfo.processInfo.systemUptime
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let lp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        guard w >= 6 * 48 else { return }
        var slot = 0
        for bit in 0..<6 { if lp[24 * stride + bit * 48 + 24] > 128 { slot |= (1 << bit) } }
        lock.lock(); defer { lock.unlock() }
        guard slot < 48, now - startedAt > (Double(ProcessInfo.processInfo.environment["WARMUP"] ?? "") ?? 4) else { return }
        let pushed = pushTimes[slot]
        if pushed > 0 && now - pushed < 0.7 { latencies.append((now - pushed) * 1000); latSeries.append((now - startedAt, (now - pushed) * 1000)) }
        frameCount += 1
        if frameCount % 12 == 0, slot < source.count {
            let full = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let src = source[slot]
            CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let ss = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
            let sp = CVPixelBufferGetBaseAddressOfPlane(src, 0)!.assumingMemoryBound(to: UInt8.self)
            let h = CVPixelBufferGetHeightOfPlane(pb, 0)
            if psnrs.isEmpty {
                let bx = w - 100, by = min(h - 100, 300)
                print("BGCHK recvFormat=\(String(format: "%08x", CVPixelBufferGetPixelFormatType(pb))) recv bg Y=\(lp[by * stride + bx]) src bg Y=\(sp[by * ss + bx]) recv text-dark min in row? size=\(w)x\(h)")
            }
            var seAll = 0.0, nAll = 0.0, seT = 0.0, nT = 0.0
            var seAll2 = 0.0, seT2 = 0.0
            var y = 60
            while y < h { 
                let ra = lp + y * stride, rb = sp + y * ss
                var x = 0
                while x < w {
                    let raw = Double(rb[x])
                    let mapped = min(255, max(0, (raw - 16) * 255.0 / 219.0))
                    let d = Double(ra[x]) - raw
                    let d2 = Double(ra[x]) - mapped
                    seAll += d * d; nAll += 1; seAll2 += d2 * d2
                    if x < Int(Double(w) * 0.55) { seT += d * d; nT += 1; seT2 += d2 * d2 }
                    x += 2
                }
                y += 4
            }
            let a1 = seAll == 0 ? 99 : 10 * log10(255 * 255 / (seAll / nAll)), a2 = seAll2 == 0 ? 99 : 10 * log10(255 * 255 / (seAll2 / nAll))
            let t1 = seT == 0 ? 99 : 10 * log10(255 * 255 / (seT / nT)), t2 = seT2 == 0 ? 99 : 10 * log10(255 * 255 / (seT2 / nT))
            psnrs.append(max(a1, a2)); psnrsText.append(max(t1, t2)); psnrSeries.append((now - startedAt, max(t1, t2)))
        }
    }
}
let probe = LatencyProbe()
let frames = (0..<48).map { drawFrame(width, height, $0, motion: content == "motion") }
print("[\(label)] \(width)x\(height) content=\(content) frames prepared; trials=\(env["TRIALS"] ?? "-") BWE_START=\(env["BWE_START"] ?? "-") DEGRADE=\(env["DEGRADE"] ?? "-") MAXBR=\(env["MAXBR"] ?? "-")")

let logger = RTCCallbackLogger()
logger.severity = .info
var notes: [String] = []
let notesLock = NSLock()
logger.start { message in
    let interesting = ["SetStartBitrate", "Video suspend", "playout", "Playout", "Negotiated codec", "Resetting compression", "QualityScaler", "overuse", "Fallback", "fallback", "ZeroPlayout", "pacing", "Pacing"]
    guard interesting.contains(where: { message.contains($0) }) else { return }
    notesLock.lock(); if notes.count < 60 { notes.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }; notesLock.unlock()
}

let host = PeerMedia(isHost: true, servers: [])
let phone = PeerMedia(isHost: false, servers: [])
host.onSignal = { phone.receive($0) }
phone.onSignal = { host.receive($0) }
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
let connectDeadline = Date().addingTimeInterval(25)
while !(hostConnected && phoneConnected && track != nil), Date() < connectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
guard hostConnected && phoneConnected else { print("FAILED to connect"); exit(1) }
probe.source = frames
probe.startedAt = ProcessInfo.processInfo.systemUptime
track?.add(probe)

if let r = env["REFRESH_AT"], let at = Double(r) {
    DispatchQueue.main.asyncAfter(deadline: .now() + at) { print("refresh trigger at t=\(at)"); host.debugForceKeyframe(width: width, height: height, bwe: Int(env["BWE_LATE"] ?? "")) }
}
var index = 0
var pumpCount = 0
let startUptime = ProcessInfo.processInfo.systemUptime
let pump = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "bench.pump", qos: .userInteractive))
pump.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
pump.setEventHandler {
    let slot = index % frames.count
    let now = ProcessInfo.processInfo.systemUptime
    host.counters.captured(idle: false)
    probe.lock.lock(); probe.pushTimes[slot] = now; probe.lock.unlock()
    host.pushFrame(frames[slot], timeStampNs: Int64(now * 1_000_000_000))
    index += 1
}
pump.resume()
let end = Date().addingTimeInterval(seconds)
while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
pump.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(1.2))

func f(_ v: Double?, _ d: Int = 1) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "-" }
print("--- per-second (host: encFPS sentFPS sentKbps targetKbps qp encMs | phone: recvFPS decFPS rendFPS gapP90 jbMs jbTargetMs decMs dropped) ---")
for i in 0..<min(hostReports.count, phoneReports.count) {
    let h = hostReports[i], p = phoneReports[i]
    print(String(format: "t=%2d host: enc %@ sent %@ %@kbps tgt %@ qp %@ encMs %@ | phone: recv %@ dec %@ rend %@ gapP90 %@ jb %@/%@ dec %@ drop %d", i + 1, f(h.encodedFPS, 0), f(h.sentFPS, 0), f(h.sentKbps, 0), f(h.targetKbps, 0), f(h.qpAverage, 0), f(h.encodeMs), f(p.receivedFPS, 0), f(p.decodedFPS, 0), f(p.renderedFPS, 0), f(p.renderGapP90Ms, 0), f(p.jitterBufferMs, 0), f(p.jitterBufferTargetMs, 0), f(p.decodeMs), p.framesDropped ?? 0))
}
func med(_ a: [Double?]) -> Double? { let s = a.compactMap { $0 }.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
let sh = Array(hostReports.dropFirst(5)), sp = Array(phoneReports.dropFirst(5))
print("SUMMARY [\(label)] steady(t>5s) median: encFPS \(f(med(sh.map { $0.encodedFPS }))) sentKbps \(f(med(sh.map { $0.sentKbps }), 0)) targetKbps \(f(med(sh.map { $0.targetKbps }), 0)) qp \(f(med(sh.map { $0.qpAverage }))) encMs \(f(med(sh.map { $0.encodeMs }))) | recvFPS \(f(med(sp.map { $0.receivedFPS }))) decFPS \(f(med(sp.map { $0.decodedFPS }))) rendFPS \(f(med(sp.map { $0.renderedFPS }))) gapP90 \(f(med(sp.map { $0.renderGapP90Ms }))) gapMax \(f(med(sp.map { $0.renderGapMaxMs }))) jitterBufMs \(f(med(sp.map { $0.jitterBufferMs }))) jbTarget \(f(med(sp.map { $0.jitterBufferTargetMs }))) decodeMs \(f(med(sp.map { $0.decodeMs }))) keyFrames \(hostReports.last?.keyFrames ?? 0) limit \(hostReports.last?.qualityLimitation ?? "-") dropped \(phoneReports.last?.framesDropped ?? 0)")
probe.lock.lock()
if env["SERIES"] == "1" {
    var buckets: [Int: ([Double], [Double])] = [:]
    for (t, l) in probe.latSeries { buckets[Int(t), default: ([], [])].0.append(l) }
    for (t, q) in probe.psnrSeries { buckets[Int(t), default: ([], [])].1.append(q) }
    for k in buckets.keys.sorted() { let (ls, qs) = buckets[k]!; let sl = ls.sorted(); print(String(format: "SERIES [%@] t=%2d lat p50 %.1f max %.1f | text PSNR %.1f dB", label, k, sl.isEmpty ? 0 : sl[sl.count / 2], sl.last ?? 0, qs.isEmpty ? 0 : qs.reduce(0, +) / Double(qs.count))) }
}
let lat = probe.latencies.sorted()
func pc(_ p: Double) -> String { lat.isEmpty ? "-" : String(format: "%.1f", lat[min(lat.count - 1, Int(Double(lat.count) * p))]) }
print("LATENCY [\(label)] push->render-callback (in-process, no network/display) n=\(lat.count) p50=\(pc(0.5)) p90=\(pc(0.9)) p99=\(pc(0.99)) max=\(lat.last.map { String(format: "%.1f", $0) } ?? "-") ms | PSNR luma all avg \(String(format: "%.1f", probe.psnrs.isEmpty ? 0 : probe.psnrs.reduce(0, +) / Double(probe.psnrs.count))) dB (min \(String(format: "%.1f", probe.psnrs.min() ?? 0))) text-region avg \(String(format: "%.1f", probe.psnrsText.isEmpty ? 0 : probe.psnrsText.reduce(0, +) / Double(probe.psnrsText.count))) dB")
probe.lock.unlock()
notesLock.lock(); for n in notes.prefix(0) { print("NOTE: \(n.prefix(200))") }; notesLock.unlock()
host.close(); phone.close()
exit(0)
