import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
func fourcc(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
func str(_ f: OSType) -> String { String(bytes: [UInt8((f >> 24) & 255), UInt8((f >> 16) & 255), UInt8((f >> 8) & 255), UInt8(f & 255)], encoding: .ascii) ?? "?" }

struct BitReader {
    var bytes: [UInt8]; var pos = 0
    init(_ raw: [UInt8]) { // strip emulation prevention
        var out: [UInt8] = []; var zeros = 0
        for b in raw { if zeros >= 2 && b == 3 { zeros = 0; continue }; out.append(b); zeros = b == 0 ? zeros + 1 : 0 }
        bytes = out
    }
    mutating func bit() -> Int { let b = (Int(bytes[pos / 8]) >> (7 - pos % 8)) & 1; pos += 1; return b }
    mutating func u(_ n: Int) -> Int { var v = 0; for _ in 0..<n { v = (v << 1) | bit() }; return v }
    mutating func ue() -> Int { var z = 0; while bit() == 0 && z < 32 { z += 1 }; return (1 << z) - 1 + (z > 0 ? u(z) : 0) }
}
func hevcSPSInfo(_ sps: [UInt8]) -> String {
    var r = BitReader(sps)
    _ = r.u(16) // nal header
    _ = r.u(4); let maxSub = r.u(3); _ = r.u(1)
    let profileSpace = r.u(2); _ = r.u(1); let profileIdc = r.u(5)
    _ = r.u(32); _ = r.u(4); _ = r.u(43); _ = r.u(1)
    let level = r.u(8)
    if maxSub > 0 { return "profile=\(profileIdc) level=\(level) (sublayers>0, not parsed)" }
    _ = r.ue() // sps id
    let chroma = r.ue()
    if chroma == 3 { _ = r.u(1) }
    let w = r.ue(), h = r.ue()
    let conf = r.u(1)
    if conf == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }
    let bdl = r.ue() + 8, bdc = r.ue() + 8
    return "profile_space=\(profileSpace) profile_idc=\(profileIdc) level_idc=\(level) (\(Double(level)/30)) chroma_format_idc=\(chroma) (1=4:2:0 2=4:2:2 3=4:4:4) size=\(w)x\(h) bitDepthLuma=\(bdl) bitDepthChroma=\(bdc)"
}
func run(_ label: String, fmt: OSType, profile: CFString?, ll: Bool = false) {
    let w = 1280, h = 720
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, w, h, fmt, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb) == kCVReturnSuccess, let pb else { print("  \(label): no CVPixelBuffer"); return }
    CVPixelBufferLockBaseAddress(pb, [])
    for p in 0..<CVPixelBufferGetPlaneCount(pb) {
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, p)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p), hh = CVPixelBufferGetHeightOfPlane(pb, p)
        for y in 0..<hh { for x in 0..<bpr { base[y * bpr + x] = p == 0 ? UInt8((x / 4 + y / 4) % 2 == 0 ? 60 : 180) : UInt8((x / 2 + y) % 200 + 20) } }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if ll { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var s: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: fmt] as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { print("  \(label): create failed"); return }
    if let profile { _ = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) }
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var out: CMSampleBuffer?
    let sem = DispatchSemaphore(value: 0)
    VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMTime(value: 0, timescale: 60), duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { st, _, sb in out = sb; sem.signal() }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); _ = sem.wait(timeout: .now() + 3)
    var hw: CFTypeRef?; _ = withUnsafeMutablePointer(to: &hw) { VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0) }
    guard let out, let f = CMSampleBufferGetFormatDescription(out) else { print("  \(label): no output"); return }
    var ptr: UnsafePointer<UInt8>?; var size = 0
    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f, parameterSetIndex: 1, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
    let info = ptr.map { hevcSPSInfo(Array(UnsafeBufferPointer(start: $0, count: size))) } ?? "?"
    print("  \(label): encHW=\(hw as? Bool ?? false) bytes=\(CMSampleBufferGetTotalSampleSize(out))\n     SPS: \(info)")
    // decode with hardware required
    for req in [true, false] {
        var d: VTDecompressionSession?
        let spec: [CFString: Any] = req ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] : [:]
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &d)
        guard st == noErr, let d else { print("     decode(requireHW=\(req)): create status \(st)"); continue }
        var pf = "none"; var dhw: CFTypeRef?
        let dsem = DispatchSemaphore(value: 0)
        let ds = VTDecompressionSessionDecodeFrame(d, sampleBuffer: out, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if let img { pf = "\(str(CVPixelBufferGetPixelFormatType(img))) \(CVPixelBufferGetWidth(img))x\(CVPixelBufferGetHeight(img)) planes=\(CVPixelBufferGetPlaneCount(img))" } else { pf = "status \(status)" }
            dsem.signal()
        }
        VTDecompressionSessionWaitForAsynchronousFrames(d); _ = dsem.wait(timeout: .now() + 2)
        _ = withUnsafeMutablePointer(to: &dhw) { VTSessionCopyProperty(d, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0) }
        print("     decode(requireHW=\(req)): submit=\(ds) usingHW=\(dhw as? Bool ?? false) output=\(pf)")
        VTDecompressionSessionInvalidate(d)
    }
    VTCompressionSessionInvalidate(s)
}
run("HEVC 420v control", fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
run("HEVC 444v (8-bit 4:4:4) no profile", fmt: fourcc("444v"), profile: nil)
run("HEVC 444f (8-bit 4:4:4 full) no profile", fmt: fourcc("444f"), profile: nil)
run("HEVC xf44 (10-bit 4:4:4 full) no profile", fmt: fourcc("xf44"), profile: nil)
run("HEVC x422 (10-bit 4:2:2)", fmt: fourcc("x422"), profile: kVTProfileLevel_HEVC_Main42210_AutoLevel)
