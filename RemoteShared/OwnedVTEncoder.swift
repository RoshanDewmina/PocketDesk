import Foundation
import VideoToolbox
import WebRTC

/// Bounded AVCC → Annex B conversion used at the public RTC encoder boundary.
/// Reject a partial NAL rather than handing malformed data to RTP packetization.
enum H264AnnexB {
    static let maximumBytes = 16 * 1024 * 1024
    static func convert(_ avcc: Data, lengthBytes: Int, parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(lengthBytes), avcc.count <= maximumBytes,
              parameterSets.count <= 8 else { return nil }
        var result = Data(), offset = 0
        let prefix = Data([0, 0, 0, 1])
        for parameter in parameterSets {
            guard !parameter.isEmpty, parameter.count <= 65536,
                  result.count + parameter.count + 4 <= maximumBytes else { return nil }
            result.append(prefix); result.append(parameter)
        }
        while offset < avcc.count {
            guard avcc.count - offset >= lengthBytes else { return nil }
            var length = 0
            for byte in avcc[offset..<(offset + lengthBytes)] { length = (length << 8) | Int(byte) }
            offset += lengthBytes
            guard length > 0, length <= avcc.count - offset,
                  result.count + length + 4 <= maximumBytes else { return nil }
            result.append(prefix); result.append(avcc[offset..<(offset + length)])
            offset += length
        }
        return result.isEmpty ? nil : result
    }
}

struct OwnedVTConfiguration: Equatable {
    enum Profile: Equatable { case constrainedBaseline, baseline, main, constrainedHigh, high }
    let profile: Profile
    let level: UInt8
    var lowLatency: Bool { level == 52 && (profile == .high || profile == .constrainedHigh) }
    // Conservative baseline bitrate bounds apply to all profiles, including High.
    var maximumKbps: UInt32 {
        let rates: [UInt8: UInt32] = [10: 64, 11: 192, 12: 384, 13: 768, 20: 2000, 21: 4000, 22: 4000,
            30: 10000, 31: 14000, 32: 20000, 40: 20000, 41: 50000, 42: 50000, 50: 100000, 51: 100000, 52: 100000]
        return rates[level] ?? 64
    }
    func acceptsSPS(_ sps: Data) -> Bool {
        guard sps.count >= 4, sps[0] & 31 == 7, sps[3] <= level else { return false }
        let observed = sps[1], constraints = sps[2]
        switch profile {
        case .constrainedBaseline: return observed == 0x42 && constraints & 0x40 != 0
        case .baseline: return observed == 0x42
        case .main: return observed == 0x4d
        case .constrainedHigh: return observed == 0x64 && constraints & 0x0c == 0x0c
        case .high: return observed == 0x64
        }
    }
    var profileProperty: CFString {
        // Low-latency hardware path requires AutoLevel, admitted only at the
        // highest advertised level. Other standard profiles use exact levels
        // where public VT exposes them; every output still passes the SPS fence.
        if lowLatency {
            return profile == .constrainedHigh ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        }
        switch profile {
        case .baseline:
            let levels: [UInt8: CFString] = [13: kVTProfileLevel_H264_Baseline_1_3, 30: kVTProfileLevel_H264_Baseline_3_0, 31: kVTProfileLevel_H264_Baseline_3_1, 32: kVTProfileLevel_H264_Baseline_3_2, 40: kVTProfileLevel_H264_Baseline_4_0, 41: kVTProfileLevel_H264_Baseline_4_1, 42: kVTProfileLevel_H264_Baseline_4_2, 50: kVTProfileLevel_H264_Baseline_5_0, 51: kVTProfileLevel_H264_Baseline_5_1, 52: kVTProfileLevel_H264_Baseline_5_2]
            return levels[level] ?? kVTProfileLevel_H264_Baseline_AutoLevel
        case .main:
            let levels: [UInt8: CFString] = [30: kVTProfileLevel_H264_Main_3_0, 31: kVTProfileLevel_H264_Main_3_1, 32: kVTProfileLevel_H264_Main_3_2, 40: kVTProfileLevel_H264_Main_4_0, 41: kVTProfileLevel_H264_Main_4_1, 42: kVTProfileLevel_H264_Main_4_2, 50: kVTProfileLevel_H264_Main_5_0, 51: kVTProfileLevel_H264_Main_5_1, 52: kVTProfileLevel_H264_Main_5_2]
            return levels[level] ?? kVTProfileLevel_H264_Main_AutoLevel
        case .high:
            let levels: [UInt8: CFString] = [30: kVTProfileLevel_H264_High_3_0, 31: kVTProfileLevel_H264_High_3_1, 32: kVTProfileLevel_H264_High_3_2, 40: kVTProfileLevel_H264_High_4_0, 41: kVTProfileLevel_H264_High_4_1, 42: kVTProfileLevel_H264_High_4_2, 50: kVTProfileLevel_H264_High_5_0, 51: kVTProfileLevel_H264_High_5_1, 52: kVTProfileLevel_H264_High_5_2]
            return levels[level] ?? kVTProfileLevel_H264_High_AutoLevel
        case .constrainedBaseline: return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case .constrainedHigh: return kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
        }
    }
    init?(parameters: [String: String]) {
        guard parameters["packetization-mode"] == "1",
              let text = parameters["profile-level-id"], text.count == 6,
              let packed = UInt32(text, radix: 16) else { return nil }
        level = UInt8(packed & 255)
        guard [10, 11, 12, 13, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52].contains(level) else { return nil }
        let constraints = UInt8((packed >> 8) & 255)
        switch packed >> 16 {
        case 0x42: profile = constraints & 0x40 != 0 ? .constrainedBaseline : .baseline
        case 0x4d where constraints == 0: profile = .main
        case 0x64 where constraints == 0x0c: profile = .constrainedHigh
        case 0x64 where constraints == 0: profile = .high
        default: return nil // Do not silently encode a different negotiated profile.
        }
    }
}

/// Public VideoToolbox encoder, with a per-peer callback and two-frame ownership bound.
/// LTR is deliberately disabled until a receiver-originated token ACK path exists;
/// submitting a frame is never evidence that the receiver received its reference.
final class OwnedVTEncoder: NSObject, RTCVideoEncoder {
    private struct Pending {
        let epoch: UUID
        let timestamp: UInt32
        let captureMs: Int64
        let rotation: RTCVideoRotation
        let submittedMs: Double
        let width: Int32
        let height: Int32
    }
    private let configuration: OwnedVTConfiguration
    private let queue = DispatchQueue(label: "farside.video.encoder", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private weak var counters: StreamCounters?
    private weak var frameTiming: HostFrameTimingLog?
    private var callback: RTCVideoEncoderCallback?
    private var session: VTCompressionSession?
    private var epoch = UUID()
    private var pending: [UInt64: Pending] = [:]
    private var nextID: UInt64 = 0
    private var width: Int32 = 0, height: Int32 = 0
    private var bitrate: UInt32 = 0, fps: UInt32 = 60
    private var maximumQP = 30
    private var restart = EncoderRestartPolicy()
    private var storedMaximumQPApplied: Bool = false
    var maximumQPApplied: Bool { serialized { storedMaximumQPApplied } }
    private var storedLowLatencyApplied: Bool = false
    var lowLatencyApplied: Bool { serialized { storedLowLatencyApplied } }
    private var storedHardwareReported: Bool?
    var hardwareReported: Bool? { serialized { storedHardwareReported } }
    var hardwareRequired: Bool { true }
    private var storedLastStatus: OSStatus = noErr
    var lastStatus: OSStatus { serialized { storedLastStatus } }
    private var storedLastStage: String = "not-started"
    var lastStage: String { serialized { storedLastStage } }

    init(configuration: OwnedVTConfiguration, counters: StreamCounters? = nil, frameTiming: HostFrameTimingLog? = nil) {
        self.configuration = configuration; self.counters = counters; self.frameTiming = frameTiming
        super.init(); queue.setSpecific(key: queueKey, value: 1)
    }
    private func serialized<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { serialized { self.callback = callback } }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        serialized {
            invalidate()
            width = Int32(settings.width); height = Int32(settings.height)
            fps = max(1, min(120, settings.maxFramerate))
            bitrate = max(1, min(configuration.maximumKbps, settings.startBitrate))
            maximumQP = max(1, min(30, settings.qpMax == 0 ? 30 : Int(settings.qpMax)))
            let limit = H264FrameBudget.level(configuration.level)
            let macroblocks = ((Int(width) + 15) / 16) * ((Int(height) + 15) / 16)
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  macroblocks <= limit.frameMacroblocks,
                  macroblocks * Int(fps) <= limit.macroblocksPerSecond else { return -1 }
            restart = EncoderRestartPolicy(); restart.keyFrameBudgetMs = 250
            restart.sessionStarted(kbps: Double(bitrate), at: ProcessInfo.processInfo.systemUptime)
            return createSession() == noErr ? 0 : -1
        }
    }
    private func createSession() -> OSStatus {
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if configuration.lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var created: VTCompressionSession?
        storedLastStage = "create"
        var status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { storedLastStatus = status; return status }
        session = created
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                             (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                             (kVTCompressionPropertyKey_ProfileLevel, configuration.profileProperty as CFTypeRef)] {
            storedLastStage = key as String
            status = VTSessionSetProperty(created, key: key, value: value)
            if status != noErr { invalidate(); storedLastStatus = status; return status }
        }
        storedLastStage = "rate"
        status = applyRate(created)
        if status != noErr { invalidate(); storedLastStatus = status; return status }
        storedMaximumQPApplied = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                               value: maximumQP as CFNumber) == noErr
        storedLastStage = "prepare"
        status = VTCompressionSessionPrepareToEncodeFrames(created)
        guard status == noErr else { invalidate(); storedLastStatus = status; return status }
        storedLastStage = "hardware"
        var hardware: CFTypeRef?
        status = withUnsafeMutablePointer(to: &hardware) {
            VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        storedHardwareReported = status == noErr ? hardware as? Bool : nil
        // Some public low-latency encoder implementations do not expose this
        // optional getter. Creation required hardware; do not reinterpret an
        // unsupported getter as measured hardware evidence or allow software.
        guard hardwareReported != false,
              status == noErr || status == kVTPropertyNotSupportedErr else {
            invalidate(); storedLastStatus = status == noErr ? -1 : status; return lastStatus
        }
        storedLowLatencyApplied = configuration.lowLatency
        storedLastStatus = noErr
        counters?.recordEncoderEvidence(VideoEncoderEvidence(path: .ownedVideoToolbox,
            maximumQPBound: maximumQPApplied ? maximumQP : nil, lowLatencyRequested: lowLatencyApplied,
            hardwareRequired: true, hardwareReported: hardwareReported))
        counters?.encoderSessionStarted()
        return noErr
    }
    private func applyRate(_ session: VTCompressionSession) -> OSStatus {
        let rate = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(bitrate) * 1000 as CFNumber)
        guard rate == noErr else { return rate }
        // Hard bounded burst window as well as a long average. A key frame is not exempt.
        let limits: [Any] = [Int(bitrate) * 1000 / 8 * 2, 1.0, Int(bitrate) * 1000 / 8 * 5, 5.0]
        let cap = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        guard cap == noErr else { return cap }
        return VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        serialized {
            bitrate = max(1, min(configuration.maximumKbps, bitrateKbit))
            let frameMacroblocks = ((Int(width) + 15) / 16) * ((Int(height) + 15) / 16)
            let maximumFPS = frameMacroblocks > 0 ? H264FrameBudget.level(configuration.level).macroblocksPerSecond / frameMacroblocks : 1
            if framerate > 0 { fps = UInt32(max(1, min(120, min(Int(framerate), maximumFPS)))) }
            restart.updateTarget(kbps: Double(bitrate)); counters?.encoderRateUpdated()
            guard let session else { return -1 }
            storedLastStatus = applyRate(session)
            return lastStatus == noErr ? 0 : -1
        }
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        serialized {
            guard session != nil else { return -1 }
            if restart.shouldRestart(at: ProcessInfo.processInfo.systemUptime) {
                invalidate()
                guard createSession() == noErr else { return -1 }
            }
            guard pending.count < 2 else { counters?.droppedBeforeEncode(); return 0 }
            guard let session, let buffer = frame.buffer as? RTCCVPixelBuffer,
                  let pixels = adaptedPixels(buffer), nextID < UInt64.max else { return -1 }
            nextID += 1
            let id = nextID, currentEpoch = epoch
            let entry = Pending(epoch: currentEpoch, timestamp: UInt32(bitPattern: frame.timeStamp),
                captureMs: frame.timeStampNs / 1_000_000, rotation: frame.rotation, submittedMs: MachClock.nowMs(), width: width, height: height)
            pending[id] = entry
            frameTiming?.submitted(ObjectIdentifier(buffer.pixelBuffer), key: entry.captureMs)
            let properties = frameTypes.contains { $0.intValue == RTCFrameType.videoFrameKey.rawValue }
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
                duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: properties, infoFlagsOut: nil) {
                    [weak self] status, flags, sample in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.completed(id: id, epoch: currentEpoch, status: status, flags: flags, sample: sample) }
                }
            if result != noErr { pending.removeValue(forKey: id); counters?.droppedBeforeEncode() }
            storedLastStatus = result
            return result == noErr ? 0 : -1
        }
    }
    private func adaptedPixels(_ buffer: RTCCVPixelBuffer) -> CVPixelBuffer? {
        if !buffer.requiresCropping(), CVPixelBufferGetWidth(buffer.pixelBuffer) == Int(width),
           CVPixelBufferGetHeight(buffer.pixelBuffer) == Int(height) { return buffer.pixelBuffer }
        let format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)
        guard [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format) else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Int(width), Int(height), format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        let count = buffer.bufferSizeForCroppingAndScaling(toWidth: width, height: height)
        guard count >= 0, count <= 32 * 1024 * 1024 else { return nil }
        var scratch = Data(count: Int(count))
        let success = scratch.withUnsafeMutableBytes { buffer.cropAndScale(to: output, withTempBuffer: $0.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
        return success ? output : nil
    }
    private func completed(id: UInt64, epoch: UUID, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard epoch == self.epoch, let entry = pending.removeValue(forKey: id), entry.epoch == epoch else { return }
        guard status == noErr, !flags.contains(.frameDropped), let sample else { counters?.encoderSilentlyDropped(1); return }
        guard let data = Self.annexB(sample, configuration: configuration) else {
            counters?.encoderSilentlyDropped(1)
            invalidate(); storedLastStatus = kVTParameterErr
            return // Never publish a bitstream outside the negotiated profile/level.
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        let now = MachClock.nowMs()
        let image = RTCEncodedImage()
        image.buffer = data; image.encodedWidth = entry.width; image.encodedHeight = entry.height
        image.timeStamp = entry.timestamp; image.captureTimeMs = entry.captureMs
        image.encodeStartMs = Int64(entry.submittedMs); image.encodeFinishMs = Int64(now)
        image.frameType = isKey ? .videoFrameKey : .videoFrameDelta; image.rotation = entry.rotation
        image.contentType = .screenshare
        // No fabricated QP: the setter's support status is not a measured slice QP.
        let codec = RTCCodecSpecificInfoH264(); codec.packetizationMode = .nonInterleaved
        if isKey { restart.lastKeyFrameBytes = data.count }
        counters?.encoded(latencyMs: max(0, now - entry.submittedMs), bytes: data.count, isKeyFrame: isKey, inFlight: pending.count + 1)
        frameTiming?.encoded(key: entry.captureMs, localRtp: entry.timestamp, bytes: data.count, atMs: now)
        if callback?(image, codec) == true { counters?.encodedFrameAccepted() }
    }
    private static func annexB(_ sample: CMSampleBuffer, configuration: OwnedVTConfiguration) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 0, count <= H264AnnexB.maximumBytes else { return nil }
        var bytes = Data(count: count)
        let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        guard copied == noErr else { return nil }
        var lengthBytes: Int32 = 0, setCount = 0
        var pointer: UnsafePointer<UInt8>?, size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: &setCount, nalUnitHeaderLengthOut: &lengthBytes) == noErr,
              setCount > 0, setCount <= 8, let firstPointer = pointer, size >= 4,
              configuration.acceptsSPS(Data(bytes: firstPointer, count: size)) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var sets: [Data] = []
        if isKey {
            for index in 0..<setCount {
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer, size > 0, size <= 65536 else { return nil }
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return H264AnnexB.convert(bytes, lengthBytes: Int(lengthBytes), parameterSets: sets)
    }
    private func invalidate() {
        epoch = UUID(); pending.removeAll()
        counters?.recordEncoderEvidence(nil)
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; storedMaximumQPApplied = false; storedLowLatencyApplied = false; storedHardwareReported = nil
    }
    func release() -> Int { serialized { invalidate(); return 0 } }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
    func implementationName() -> String { "Farside public VideoToolbox H264" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }
}

/// One callback in progress plus one newest pending image. Never invoke an
/// outward RTC callback on the queue that owns VideoToolbox or codec selection.
final class VideoEncoderCallbackDelivery: @unchecked Sendable {
    private struct Output {
        let epoch: UUID
        let image: RTCEncodedImage
        let info: any RTCCodecSpecificInfo
    }
    private let fence = NSRecursiveLock()
    private let mailbox = NSLock()
    private let queue = DispatchQueue(label: "farside.video.encoder-callback")
    private var epoch = UUID()
    private var closed = true
    private var pending: Output?
    private var scheduled = false
    private var callback: RTCVideoEncoderCallback?
    private weak var counters: StreamCounters?
    init(counters: StreamCounters? = nil) { self.counters = counters }
    func setCallback(_ next: RTCVideoEncoderCallback?) {
        fence.lock(); defer { fence.unlock() }
        callback = next
        mailbox.lock(); pending = nil; mailbox.unlock()
    }
    func activate() -> UUID {
        fence.lock(); defer { fence.unlock() }
        mailbox.lock(); defer { mailbox.unlock() }
        epoch = UUID(); closed = false; pending = nil
        return epoch
    }
    func isCurrent(_ candidate: UUID) -> Bool {
        mailbox.lock(); defer { mailbox.unlock() }
        return !closed && epoch == candidate
    }
    func enqueue(_ image: RTCEncodedImage, info: any RTCCodecSpecificInfo, epoch candidate: UUID) {
        // This path may run on the owned encoder queue. It must NEVER wait for
        // the callback fence, whose caller may synchronously release that encoder.
        mailbox.lock()
        guard !closed, epoch == candidate else { mailbox.unlock(); return }
        let replaced = pending != nil
        pending = Output(epoch: candidate, image: image, info: info)
        let shouldSchedule = !scheduled
        scheduled = true
        mailbox.unlock()
        if replaced { counters?.encoderDeliveryDropped() }
        if shouldSchedule { queue.async { [weak self] in self?.deliver() } }
    }
    private func deliver() {
        while true {
            fence.lock()
            mailbox.lock()
            guard let output = pending else {
                scheduled = false; mailbox.unlock(); fence.unlock(); return
            }
            pending = nil
            let valid = !closed && output.epoch == epoch
            mailbox.unlock()
            if valid, callback?(output.image, output.info) == true, isCurrent(output.epoch) { counters?.encodedFrameAccepted() }
            fence.unlock()
        }
    }
    func invalidate() {
        // Waits for an earlier outward callback; a callback may itself retire
        // this delivery through the recursive fence without an encoder queue cycle.
        fence.lock(); defer { fence.unlock() }
        mailbox.lock(); closed = true; epoch = UUID(); pending = nil; mailbox.unlock()
    }
}

/// Prefer the owned public path; a rejected public VT configuration retains the
/// same negotiated codec in the compatibility encoder. Fallback is per session.
final class ResilientVTEncoder: NSObject, RTCVideoEncoder {
    private let owned: any RTCVideoEncoder
    private let fallback: any RTCVideoEncoder
    private let maximumKbps: UInt32
    private let delivery: VideoEncoderCallbackDelivery
    private let queue = DispatchQueue(label: "farside.video.encoder-selection")
    private let key = DispatchSpecificKey<UInt8>()
    private var active: (any RTCVideoEncoder)?
    private var settings: RTCVideoEncoderSettings?
    private var cores: Int32 = 1
    private var deliveryEpoch: UUID?
    private var usingOwned = false
    init(configuration: OwnedVTConfiguration, codecInfo: RTCVideoCodecInfo,
         counters: StreamCounters?, frameTiming: HostFrameTimingLog?) {
        owned = OwnedVTEncoder(configuration: configuration, counters: counters, frameTiming: frameTiming)
        fallback = DesktopH264Encoder(codecInfo: codecInfo, counters: counters, frameTiming: frameTiming)
        maximumKbps = configuration.maximumKbps
        delivery = VideoEncoderCallbackDelivery(counters: counters)
        super.init(); queue.setSpecific(key: key, value: 1)
    }
    #if DEBUG
    init(preferred: any RTCVideoEncoder, fallback: any RTCVideoEncoder, counters: StreamCounters? = nil) {
        owned = preferred; self.fallback = fallback; maximumKbps = 100_000
        delivery = VideoEncoderCallbackDelivery(counters: counters)
        super.init(); queue.setSpecific(key: key, value: 1)
    }
    #endif
    private func serialized<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: key) != nil ? body() : queue.sync(execute: body)
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { delivery.setCallback(callback) }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        // Fence operations precede acquisition of the selection queue. An outward
        // callback can ask for implementationName/release/rate synchronously.
        let epoch = delivery.activate()
        return serialized {
            if let active { _ = active.release() }
            active = nil
            guard delivery.isCurrent(epoch) else { return -1 }
            let saved = RTCVideoEncoderSettings()
            saved.name = settings.name; saved.width = settings.width; saved.height = settings.height
            saved.startBitrate = min(maximumKbps, max(1, settings.startBitrate))
            saved.maxBitrate = min(maximumKbps, settings.maxBitrate)
            saved.minBitrate = min(saved.startBitrate, settings.minBitrate)
            saved.maxFramerate = settings.maxFramerate; saved.qpMax = settings.qpMax; saved.mode = settings.mode
            self.settings = saved; cores = numberOfCores; deliveryEpoch = epoch
            let enqueue: RTCVideoEncoderCallback = { [delivery] image, info in
                delivery.enqueue(image, info: info, epoch: epoch)
                // Actual acceptance is counted after the outward callback returns.
                return false
            }
            owned.setCallback(enqueue)
            let result = owned.startEncode(with: saved, numberOfCores: numberOfCores)
            if result == 0 { active = owned; usingOwned = true; return 0 }
            _ = owned.release()
            fallback.setCallback(enqueue)
            let compatible = fallback.startEncode(with: saved, numberOfCores: numberOfCores)
            if compatible == 0 { active = fallback; usingOwned = false }
            return compatible
        }
    }
    func release() -> Int {
        delivery.invalidate()
        return serialized { let old = active; active = nil; settings = nil; deliveryEpoch = nil; return old?.release() ?? 0 }
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        serialized {
            let result = active?.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes) ?? -1
            guard result != 0, usingOwned, let settings, let epoch = deliveryEpoch, delivery.isCurrent(epoch) else { return result }
            _ = owned.release()
            fallback.setCallback { [delivery] image, info in delivery.enqueue(image, info: info, epoch: epoch); return false }
            guard fallback.startEncode(with: settings, numberOfCores: cores) == 0 else { active = nil; return -1 }
            active = fallback; usingOwned = false
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        }
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        serialized {
            let bounded = max(1, min(maximumKbps, bitrateKbit))
            settings?.startBitrate = bounded
            if framerate > 0 { settings?.maxFramerate = framerate }
            return active?.setBitrate(bounded, framerate: framerate) ?? -1
        }
    }
    func implementationName() -> String { serialized { active?.implementationName() ?? "Farside owned VT with codec-compatible fallback" } }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { serialized { active?.scalingSettings() } }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }
}

/// Owner rollback applies when a new codec session is created, never midway
/// through a negotiated stream. Default candidate uses the owned public encoder.
enum VideoEncoderCompatibility {
    static let key = "FarsideCompatibilityVideoEncoder"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = UserDefaults.standard.bool(forKey: key)
    static var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock(); UserDefaults.standard.set(newValue, forKey: key) }
    }
}
