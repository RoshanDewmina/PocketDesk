import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

setvbuf(stdout, nil, _IOLBF, 0)
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func machToMS(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    let lock = NSLock()
    var complete = 0, idle = 0, other = 0
    var latencies: [Double] = []
    var intervals: [Double] = []
    var lastComplete = 0.0
    var dirtyCounts: [Int] = []
    var dirtyCoverage: [Double] = []
    var w = 0.0, h = 0.0
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let nowMach = mach_absolute_time()
        lock.lock(); defer { lock.unlock() }
        switch status {
        case .complete:
            complete += 1
            let nowMS = machToMS(nowMach)
            if lastComplete > 0 { intervals.append(nowMS - lastComplete) }
            lastComplete = nowMS
            if let dt = att[.displayTime] as? UInt64 { latencies.append(nowMS - machToMS(dt)) }
            if let rects = att[.dirtyRects] as? [Any] {
                var area = 0.0
                for r in rects { if let v = r as? NSValue { let rr = v.rectValue; area += Double(rr.width * rr.height) } else if let d = r as? [String: Any] { let rr = CGRect(dictionaryRepresentation: d as CFDictionary) ?? .zero; area += Double(rr.width * rr.height) } }
                dirtyCounts.append(rects.count)
                if w > 0 { dirtyCoverage.append(min(1, area / (w * h))) }
            }
        case .idle: idle += 1
        default: other += 1
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stream stopped: \(error)") }
    func reset() { lock.lock(); complete = 0; idle = 0; other = 0; latencies = []; intervals = []; lastComplete = 0; dirtyCounts = []; dirtyCoverage = []; lock.unlock() }
}
func pct(_ a: [Double], _ p: Double) -> String { let s = a.sorted(); return s.isEmpty ? "-" : String(format: "%.1f", s[min(s.count - 1, Int(Double(s.count) * p))]) }

func runCase(display: SCDisplay, name: String, width: Int, height: Int, interval: CMTime, depth: Int, format: OSType, seconds: Double) async {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = width; cfg.height = height; cfg.minimumFrameInterval = interval; cfg.queueDepth = depth
    cfg.pixelFormat = format; cfg.showsCursor = true; cfg.capturesAudio = false
    let sink = Sink()
    sink.w = Double(width); sink.h = Double(height)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: sink)
    do {
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.\(name)", qos: .userInteractive))
        try await stream.startCapture()
    } catch { print("[\(name)] start failed: \(error)"); return }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    sink.reset()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    sink.lock.lock()
    let c = sink.complete, i = sink.idle, o = sink.other
    let lat = sink.latencies, iv = sink.intervals, dc = sink.dirtyCounts.map(Double.init), cov = sink.dirtyCoverage
    sink.lock.unlock()
    try? await stream.stopCapture()
    print("[\(name)] \(width)x\(height) depth=\(depth) interval=\(interval.value)/\(interval.timescale) fmt=\(String(format: "%08x", format)) over \(Int(seconds))s: complete=\(c) (\(String(format: "%.1f", Double(c) / seconds))/s) idle=\(i) other=\(o) | callback-minus-displayTime ms p50=\(pct(lat, 0.5)) p90=\(pct(lat, 0.9)) max=\(pct(lat, 0.999)) | complete-interval ms p50=\(pct(iv, 0.5)) p90=\(pct(iv, 0.9)) p99=\(pct(iv, 0.99)) | dirtyRects/frame p50=\(pct(dc, 0.5)) max=\(pct(dc, 0.999)) coverage p50=\(String(format: "%.2f", cov.sorted().isEmpty ? 0 : cov.sorted()[cov.count / 2])) p90=\(String(format: "%.2f", cov.sorted().isEmpty ? 0 : cov.sorted()[min(cov.count - 1, Int(Double(cov.count) * 0.9))]))")
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { print("no display"); exit(1) }
        print("display \(display.width)x\(display.height) points; refresh unknown; id \(display.displayID)")
        let scale = 2
        let W = display.width * scale, H = display.height * scale
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        await runCase(display: display, name: "A depth3 1/60", width: 1920, height: 1248, interval: CMTime(value: 1, timescale: 60), depth: 3, format: v420, seconds: 10)
        await runCase(display: display, name: "B depth8 1/60", width: 1920, height: 1248, interval: CMTime(value: 1, timescale: 60), depth: 8, format: v420, seconds: 10)
        await runCase(display: display, name: "C depth3 zero", width: 1920, height: 1248, interval: .zero, depth: 3, format: v420, seconds: 10)
        await runCase(display: display, name: "D depth3 1/60 native", width: W, height: H, interval: CMTime(value: 1, timescale: 60), depth: 3, format: v420, seconds: 10)
        await runCase(display: display, name: "E depth3 1/60 BGRA", width: 1920, height: 1248, interval: CMTime(value: 1, timescale: 60), depth: 3, format: kCVPixelFormatType_32BGRA, seconds: 10)
        exit(0)
    } catch { print("ERROR: \(error)"); exit(2) }
}
RunLoop.main.run()
