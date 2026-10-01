import Foundation
import VideoToolbox
import WebRTC

/// A one-frame format capability probe, never sustained 4K/120 fps acceptance.
/// Positive cache is tied to the exact OS/model, probe revision and pinned RTP implementation.
enum NativeHEVCCapability {
    private static let state = HEVCProcessState()
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static var isDisabledThisLaunch: Bool { !state.permits(at: now) }
    static func begin() -> HEVCRun { HEVCRun(at: now) }
    static func failed(_ run: HEVCRun) { if run.markFailed() { state.failed(at: now) } }
    static func ended(_ run: HEVCRun) { if let failed = run.markEnded() { state.ended(failed: failed, startedAt: run.startedAt, at: now) } }
    static func permits(isHost: Bool) -> Bool {
        !VideoEncoderCompatibility.isOn && state.permits(at: now) && supportsDecode && (!isHost || supportsEncode)
    }
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = supportsDecode
            #if os(macOS)
            _ = supportsEncode
            #endif
        }
    }
    static let supportsDecode: Bool = probe(role: "decode") { decodeFixture() }
    static let supportsEncode: Bool = probe(role: "encode") { encodeFixture() }
    static var fixture: Data { Data(base64Encoded: "AAAAAUABDAH//yFgAAADALAAAAMAAAMAmRcCQAAAAAFCAQEhYAAAAwCwAAADAAADAJmgAeAgAhxYgXuRZFL/y5/E/ogAAAABRAHAcvBTJAAAAAFOAQUyR1ZK3FxMQz+U78URPNFDqAEAAAMABAMAAAMAAwIAtxsACwAAAwAAAwAACGYMA5ErAQ3/////gAAAAAEoAa8QBENdTPNLJHHDBBA+888886666666666666666666666666666666666666666666666667Dolx//n13k5C3THDnK1AAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwADbpGFS7z8QLhiAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAi4ALob4L5YAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAGzAEUc7gAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADATEHHgAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAFHAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAABsQAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAA2IAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAnYAAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAABGQAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAENAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAhoAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAEVAAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAWUAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAU8AAADAAADAAADAAADAAADAAADAAADAAADAAADAAARMAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAALiAAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAF/AAAADAAADAAADAAADAAADAAADAAADAAADAAADAAC7gAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwABPwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwACBgAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwADBgAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAELAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAFlAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAHLAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAJSAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAKuAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAL+AAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwANyAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAO+AAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAQMAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAQ8AAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwARkAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwARsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASkAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASkAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwATEAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwASsAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwCygA==")! }
    private static func probe(role: String, perform: @escaping () -> Bool) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let key = "Farside.HEVC.Main51.HighTier.probe.v1.RTC153." + role + "." + NativeCodecCapability.systemAndModel
        if UserDefaults.standard.object(forKey: key) != nil, UserDefaults.standard.bool(forKey: key) { return true }
        let result = HEVCProbeResult(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let valid = perform(); result.set(valid)
            if valid { UserDefaults.standard.set(true, forKey: key) }
            group.leave()
        }
        guard group.wait(timeout: .now() + .seconds(3)) == .success else { return false }
        return result.value
        #endif
    }
    static func decodeFixture() -> Bool {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return false }
        let decoder = OwnedHEVCDecoder(), result = HEVCProbeResult(), ready = DispatchSemaphore(value: 0)
        decoder.setCallback { frame in
            result.set(frame.width == 3840 && frame.height == 2160); ready.signal()
        }
        guard decoder.startDecode(withNumberOfCores: 1) == 0 else { return false }
        defer { _ = decoder.release() }
        let image = RTCEncodedImage(); image.buffer = fixture; image.timeStamp = 90000; image.captureTimeMs = 1000
        guard decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0,
              ready.wait(timeout: .now() + .seconds(2)) == .success else { return false }
        return result.value // Decoder specification requires hardware; no software fallback.
    }
    static func encodeFixture() -> Bool {
        let configuration = OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters)!
        let encoder = OwnedVTEncoder(configuration: configuration)
        let ready = DispatchSemaphore(value: 0), result = HEVCProbeResult()
        let settings = RTCVideoEncoderSettings(); settings.name = "H265"
        settings.width = 3840; settings.height = 2160; settings.maxFramerate = 60
        settings.startBitrate = 12000; settings.maxBitrate = 12000; settings.qpMax = 30; settings.mode = .screensharing
        encoder.setCallback { image, _ in
            result.set(H26xAnnexB.split(image.buffer)?.contains { (($0.first ?? 0) >> 1) & 63 == 33 && configuration.acceptsSPS($0) } == true)
            ready.signal(); return true
        }
        guard encoder.startEncode(with: settings, numberOfCores: 1) == 0 else { return false }
        defer { _ = encoder.release() }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { return false }
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(pixels, plane), plane == 0 ? 16 : 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1000000000)
        frame.timeStamp = 90000
        guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]) == 0,
              ready.wait(timeout: .now() + .seconds(2)) == .success else { return false }
        return result.value
    }
}
private final class HEVCProbeResult: @unchecked Sendable {
    private let lock = NSLock(); private var result = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ value: Bool) { lock.lock(); result = value; lock.unlock() }
}
/// A failure falls back to H.264 for that session and its reconnect, not for the life of the host.
/// The next session after `retryAfter` tries HEVC again; a second failure keeps H.264 for this launch,
/// so a Mac whose HEVC keeps failing starts sessions on H.264 instead of tearing them down.
struct HEVCFallbackPolicy: Equatable {
    static let retryAfter: TimeInterval = 10 * 60
    static let failuresBeforeH264 = 2
    static let cleanSession: TimeInterval = 60
    private(set) var failures = 0
    private(set) var lastFailure: TimeInterval?

    func permits(at now: TimeInterval) -> Bool {
        guard let lastFailure else { return true }
        return failures < Self.failuresBeforeH264 && now - lastFailure >= Self.retryAfter
    }
    mutating func failed(at now: TimeInterval) { failures += 1; lastFailure = now }
    mutating func ended(failed: Bool, startedAt: TimeInterval, at now: TimeInterval) {
        guard !failed, now - startedAt >= Self.cleanSession else { return }
        failures = 0; lastFailure = nil
    }
}
/// One peer's HEVC outcome, reported to the launch-wide policy at most once each way.
final class HEVCRun: @unchecked Sendable {
    let startedAt: TimeInterval
    private let lock = NSLock(); private var failed = false, ended = false
    init(at now: TimeInterval) { startedAt = now }
    func markFailed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !ended else { return false }
        failed = true; return true
    }
    func markEnded() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return nil }
        ended = true; return failed
    }
}
private final class HEVCProcessState: @unchecked Sendable {
    private let lock = NSLock(); private var policy = HEVCFallbackPolicy()
    func permits(at now: TimeInterval) -> Bool { lock.lock(); defer { lock.unlock() }; return policy.permits(at: now) }
    func failed(at now: TimeInterval) { lock.lock(); policy.failed(at: now); lock.unlock() }
    func ended(failed: Bool, startedAt: TimeInterval, at now: TimeInterval) {
        lock.lock(); policy.ended(failed: failed, startedAt: startedAt, at: now); lock.unlock()
    }
}
