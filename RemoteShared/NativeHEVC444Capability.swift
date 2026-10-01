import Foundation
import VideoToolbox
import WebRTC

/// A 64-pixel one-frame format probe; not a 4K/120 fps or physical-phone acceptance claim.
enum NativeHEVC444Capability {
    private static let state = HEVC444ProbeState()
    static var disabledThisLaunch: Bool { state.disabled }
    static func failed() { state.disable() }
    static func permits(isHost: Bool) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard StreamTuning.current.hevc, HEVC444Policy.enabled, !VideoEncoderCompatibility.isOn, !state.disabled else { return false }
        return HEVC444Policy.permits(preference: true, simulator: false, disabled: state.disabled,
            decoder: supportsDecode, encoder: isHost ? supportsEncode : false, isHost: isHost)
        #endif
    }
    static func warmUp() {
        guard HEVC444Policy.enabled else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = supportsDecode
            #if os(macOS)
            _ = supportsEncode
            #endif
        }
    }
    static let supportsDecode: Bool = probe(role: "decode", perform: decodeFixture)
    static let supportsEncode: Bool = probe(role: "encode", perform: encodeFixture)
    // Synthetic neutral-gray public hardware sample, parent receipt work/chroma-feasibility/README.md.
    static var fixture: Data { Data(base64Encoded: "AAAAAUABDAH//wQIAAADAL4IAAADAAAeFcCQAAAAAUIBAQQIAAADAL4IAAADAAAekAKECDgYfECvciyogAAAAAFEAcAsvBTJAAAAAU4BBTJHVkrcXExDP5TvxRE80UOoAQAAAwABAwAAAwABAgAAhwALAAADAAADAAANwAwDkSsBDf////+AAAAAASgBrxCLCOiGPv/80w4oV4XVnVr6mNDAkYefM6fqXSk=")! }
    private static func probe(role: String, perform: @escaping () -> Bool) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let key = HEVC444Policy.cacheKey(role: role, systemAndModel: NativeCodecCapability.systemAndModel) else { return false }
        if UserDefaults.standard.bool(forKey: key) { return true }
        let result = HEVC444ProbeState(), done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async { result.set(perform()); done.leave() }
        guard done.wait(timeout: .now() + .seconds(3)) == .success, result.value else { return false }
        // Only the timely positive waiter persists. A late success or timeout never populates cache.
        UserDefaults.standard.set(true, forKey: key)
        return true
        #endif
    }
    static func decodeFixture() -> Bool {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
              let config = OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.fullColorCodecInfo.parameters) else { return false }
        let decoder = OwnedHEVCDecoder(configuration: config), result = HEVC444ProbeState(), done = DispatchSemaphore(value: 0)
        decoder.setCallback { frame in
            if let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
                result.set(frame.width == 64 && frame.height == 64 && HEVC444PixelTransfer.isFullColor(pixels))
            }
            done.signal()
        }
        guard decoder.startDecode(withNumberOfCores: 1) == 0 else { return false }
        defer { _ = decoder.release() }
        let image = RTCEncodedImage(); image.buffer = fixture; image.timeStamp = 90000; image.captureTimeMs = 1000
        guard decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0,
              done.wait(timeout: .now() + .seconds(2)) == .success else { return false }
        return result.value
    }
    static func encodeFixture() -> Bool {
        guard let config = OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.fullColorCodecInfo.parameters) else { return false }
        let encoder = OwnedVTEncoder(configuration: config), result = HEVC444ProbeState(), done = DispatchSemaphore(value: 0)
        let settings = RTCVideoEncoderSettings(); settings.name = "H265"; settings.width = 64; settings.height = 64
        settings.maxFramerate = 60; settings.startBitrate = 1000; settings.maxBitrate = 1000; settings.qpMax = 30; settings.mode = .screensharing
        encoder.setCallback { image, _ in
            result.set(H26xAnnexB.split(image.buffer)?.contains { HEVC444SPS.parse($0) != nil } == true)
            done.signal(); return true
        }
        guard encoder.startEncode(with: settings, numberOfCores: 1) == 0 else { return false }
        defer { _ = encoder.release() }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { return false }
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else { return false }
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 128, CVPixelBufferGetBytesPerRow(pixels) * 64) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1000000000); frame.timeStamp = 90000
        guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]) == 0,
              done.wait(timeout: .now() + .seconds(2)) == .success else { return false }
        return result.value
    }
}
private final class HEVC444ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = false, stopped = false
    var disabled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func set(_ result: Bool) { lock.lock(); valid = result; lock.unlock() }
    func disable() { lock.lock(); stopped = true; lock.unlock() }
}
