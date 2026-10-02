import Foundation
import VideoToolbox
import WebRTC

protocol OwnedVideoConfiguration {
    var codecType: CMVideoCodecType { get }
    var maximumKbps: UInt32 { get }
    var lowLatency: Bool { get }
    var fullColor444: Bool { get }
    var profileProperty: CFString { get }
    func fits(width: Int, height: Int, fps: Int) -> Bool
    func acceptsSPS(_ data: Data) -> Bool
    func codecSpecificInfo() -> any RTCCodecSpecificInfo
}

extension OwnedVideoConfiguration { var fullColor444: Bool { false } }

extension OwnedVTConfiguration: OwnedVideoConfiguration {
    var codecType: CMVideoCodecType { kCMVideoCodecType_H264 }
    func fits(width: Int, height: Int, fps: Int) -> Bool {
        let limit = H264FrameBudget.level(level), blocks = ((width + 15) / 16) * ((height + 15) / 16)
        return width > 0 && height > 0 && width <= 4096 && height <= 4096 && fps > 0 && blocks <= limit.frameMacroblocks && blocks * fps <= limit.macroblocksPerSecond
    }
    func codecSpecificInfo() -> any RTCCodecSpecificInfo {
        let info = RTCCodecSpecificInfoH264(); info.packetizationMode = .nonInterleaved; return info
    }
}

/// Main1 by default, or explicitly negotiated Main444-eight-bit with the same tier/level ceiling.
/// No HDR, cadence or physical-device claim follows from format admission.
struct OwnedHEVCConfiguration: OwnedVideoConfiguration {
    static var codecInfo: RTCVideoCodecInfo { RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "tier-flag": "1", "level-id": "153", "tx-mode": "SRST"]) }
    static var fullColorCodecInfo: RTCVideoCodecInfo { RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "4", "tier-flag": "1", "level-id": "153", "tx-mode": "SRST"]) }
    let level: UInt8
    let tier: UInt8
    let profile: UInt8
    var fullColor444: Bool { profile == 4 }
    var codecType: CMVideoCodecType { kCMVideoCodecType_HEVC }
    var maximumKbps: UInt32 { [UInt8(120): 12_000, 123: 20_000, 150: 25_000, 153: 40_000][level] ?? 12_000 }
    var lowLatency: Bool { false } // Standard HEVC hardware; no unsupported low-latency request.
    var profileProperty: CFString { kVTProfileLevel_HEVC_Main_AutoLevel }
    init?(parameters: [String: String]) {
        guard let profile = UInt8(parameters["profile-id"] ?? ""), [1, 4].contains(profile), let tier = UInt8(parameters["tier-flag"] ?? ""), tier <= 1, parameters["tx-mode"] == "SRST",
              let level = UInt8(parameters["level-id"] ?? ""), [120, 123, 150, 153].contains(level) else { return nil }
        self.level = level; self.tier = tier; self.profile = profile
    }
    func fits(width: Int, height: Int, fps: Int) -> Bool {
        let picture = level < 150 ? 2_228_224 : 8_912_896
        let rate = [UInt8(120): 66_846_720, 123: 133_693_440, 150: 267_386_880, 153: 534_773_760][level] ?? 0
        guard width > 0, height > 0, width <= 4096, height <= 4096, fps > 0, fps <= 120 else { return false }
        return width * height <= picture && width * height * fps <= rate
    }
    func acceptsSPS(_ data: Data) -> Bool {
        if fullColor444 {
            guard let actual = HEVC444SPS.parse(data), actual.tier <= tier, actual.level <= level else { return false }
            return fits(width: actual.width, height: actual.height, fps: 1)
        }
        guard data.count >= 2, (data[0] >> 1) & 63 == 33 else { return false }
        let bytes = H26xAnnexB.rbsp(data.dropFirst(2))
        // sps_video_parameter_set_id/max_sub_layers/temporal_nesting then general profile/tier/level.
        guard bytes.count >= 13, bytes[1] & 0xdf == 1, (bytes[1] >> 5) & 1 <= tier, [30, 60, 63, 90, 93, 120, 123, 150, 153].contains(bytes[12]), bytes[12] <= level else { return false }
        return true
    }
    func codecSpecificInfo() -> any RTCCodecSpecificInfo { GenericHEVCInfo() }
}
private final class GenericHEVCInfo: NSObject, RTCCodecSpecificInfo {}

enum H26xAnnexB {
    static func rbsp(_ bytes: Data.SubSequence) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            result.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
    }
    static func split(_ data: Data) -> [Data]? {
        guard !data.isEmpty, data.count <= H264AnnexB.maximumBytes else { return nil }
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        guard starts.first?.0 == 0, starts.count <= 4096 else { return nil }
        var result: [Data] = []
        for index in starts.indices {
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard end > starts[index].1 else { return nil }
            result.append(Data(bytes[starts[index].1..<end]))
        }
        return result
    }
}

/// Terminal owned decoder: public output blocks retain frames, never raw refcon pointers.
final class OwnedHEVCDecoder: NSObject, RTCVideoDecoder {
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "farside.hevc.decode")
    private let key = DispatchSpecificKey<UInt8>()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sets: [Int: Data] = [:]
    private var generation = UUID()
    private var opened = false
    private var failureReported = false
    #if DEBUG
    var submissionStatusForTesting: OSStatus?
    #endif
    private var pending: Set<UUID> = []
    private var callback: RTCVideoDecoderCallback?
    private let deliveryMailbox = NSLock()
    private let deliveryQueue = DispatchQueue(label: "farside.hevc.decoded-delivery")
    private var deliveryPending: (RTCVideoFrame, UUID, (submitMs: Double, callbackMs: Double, ownershipMs: Double)?)?
    private var deliveryScheduled = false
    private weak var timing: PhoneFrameTimingLog?
    private let configuration: OwnedHEVCConfiguration
    private let onFailure: (() -> Void)?
    private let recoveryEnabled: Bool
    private let clock: () -> Double
    private var recoveryNeeded = false
    private var lastRecoveryRequestMs = -Double.infinity
    /// At most one key-frame request per this interval while bad data keeps arriving.
    static let recoveryRequestIntervalMs = 500.0
    /// libwebrtc treats any error from `decode` as a failed frame and asks the Mac for a key frame
    /// (VideoReceiveStream2 sets keyframe_required and sends a PLI); the owned encoder answers at once.
    /// Returned for one frame after an asynchronous bad-data or missing-reference error, which used to
    /// be swallowed and left the picture to VideoToolbox's own key-frame cadence.
    static let requestKeyFrameResult = -1
    init(configuration: OwnedHEVCConfiguration = OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters)!, timing: PhoneFrameTimingLog? = nil, onFailure: (() -> Void)? = nil,
         recovery: Bool = HEVCDecodeRecoverySwitch.isOn, clock: @escaping () -> Double = { MachClock.nowMs() }) {
        self.configuration = configuration; self.timing = timing; self.onFailure = onFailure; self.recoveryEnabled = recovery; self.clock = clock
        super.init(); queue.setSpecific(key: key, value: 1)
    }
    private func serialized<T>(_ body: () -> T) -> T { DispatchQueue.getSpecific(key: key) != nil ? body() : queue.sync(execute: body) }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { lock.lock(); self.callback = callback; lock.unlock() }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { serialized { opened = true; return 0 } }
    func release() -> Int {
        lock.lock(); defer { lock.unlock() }
        return serialized { retire(); opened = false; sets.removeAll(); format = nil; deliveryMailbox.lock(); deliveryPending = nil; deliveryMailbox.unlock(); return 0 }
    }
    private func fail(_ status: OSStatus) {
        guard status != noErr, status != kVTVideoDecoderBadDataErr, status != kVTVideoDecoderReferenceMissingErr else {
            if status != noErr, recoveryEnabled { recoveryNeeded = true }
            return
        }
        retire(); opened = false
        guard !failureReported else { return }; failureReported = true
        DispatchQueue.global(qos: .utility).async { [onFailure] in onFailure?() }
    }
    private func retire() { generation = UUID(); pending.removeAll(); if let session { VTDecompressionSessionInvalidate(session) }; session = nil }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        serialized {
            guard opened, abs(Double(image.captureTimeMs)) < 1e12, let nals = H26xAnnexB.split(image.buffer) else { return -1 }
            timing?.received(wireRtp: image.timeStamp, bytes: image.buffer.count, atMs: MachClock.nowMs())
            var changed = false, payload = Data()
            for nal in nals {
                guard nal.count >= 2, nal[0] & 0x81 == 0, nal[1] & 0xf8 == 0, nal[1] & 7 != 0 else { return -1 }
                let type = Int((nal[0] >> 1) & 63)
                if (32...34).contains(type) {
                    guard nal.count <= 65536 else { return -1 }
                    if sets[type] != nal { sets[type] = nal; changed = true }
                } else {
                    var size = UInt32(nal.count).bigEndian
                    withUnsafeBytes(of: &size) { payload.append(contentsOf: $0) }; payload.append(nal)
                }
            }
            if changed || session == nil {
                guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else { return -1 }
                let config = configuration
                guard config.acceptsSPS(sps) else { return -1 }
                let data = [vps, sps, pps].map { $0 as NSData }
                var pointers = data.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }, sizes = data.map(\.length)
                var next: CMVideoFormatDescription?
                let created = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &next)
                guard created == noErr, let next else { return -1 }
                let dimensions = CMVideoFormatDescriptionGetDimensions(next)
                guard config.fits(width: Int(dimensions.width), height: Int(dimensions.height), fps: 1) else { return -1 }
                retire(); format = next
                let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: next,
                    decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: config.fullColor444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
                guard result == noErr else { fail(result); return -1 }
            }
            guard let session, let format, !payload.isEmpty else { return -1 }
            // Rejecting a frame breaks the HEVC reference chain and makes WebRTC request a keyframe;
            // a burst then triggers more keyframes. Bound in-flight work by waiting instead.
            if pending.count >= 2 { VTDecompressionSessionWaitForAsynchronousFrames(session) }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return -1 }
            guard payload.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }) == noErr else { return -1 }
            var sample: CMSampleBuffer?, size = payload.count
            var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: image.captureTimeMs, timescale: 1000), decodeTimeStamp: .invalid)
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return -1 }
            let ticket = UUID(), epoch = generation, rtp = image.timeStamp, rotation = image.rotation, capture = image.captureTimeMs
            pending.insert(ticket)
            #if DEBUG
            if let injected = submissionStatusForTesting {
                pending.remove(ticket); fail(injected); return injected == noErr ? 0 : -1
            }
            #endif
            if recoveryNeeded, clock() - lastRecoveryRequestMs >= Self.recoveryRequestIntervalMs {
                recoveryNeeded = false; lastRecoveryRequestMs = clock(); pending.remove(ticket)
                return Self.requestKeyFrameResult
            }
            // Apple public output-handler decode API (official docs checked 1 October 2026);
            // timestamp at entry before the ownership hop.
            // https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:infoflagsout:outputhandler:)
            let submitMs = timing?.renderTimingEnabled == true ? MachClock.nowMs() : nil
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, flags, pixels, _, _ in
                let callbackMs = submitMs != nil ? MachClock.nowMs() : nil
                guard let self else { return }
                self.queue.async { [weak self] in
                    let ownershipMs = submitMs != nil ? MachClock.nowMs() : nil
                    guard let self, self.generation == epoch, self.pending.remove(ticket) != nil else { return }
                    guard status == noErr, !flags.contains(.frameDropped), let pixels else {
                        if status != noErr { self.fail(status) }
                        return
                    }
                    guard !self.configuration.fullColor444 || HEVC444PixelTransfer.isFullColor(pixels) else { self.fail(kVTVideoDecoderUnsupportedDataFormatErr); return }
                    let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: rotation, timeStampNs: capture * 1_000_000)
                    frame.timeStamp = Int32(bitPattern: rtp)
                    self.timing?.decoded(rtp: frame.timeStamp, atMs: MachClock.nowMs())
                    let decodeTimes: (submitMs: Double, callbackMs: Double, ownershipMs: Double)?
                    if let submitMs, let callbackMs, let ownershipMs {
                        decodeTimes = (submitMs, callbackMs, ownershipMs)
                    } else { decodeTimes = nil }
                    self.offerDecoded(frame, epoch: epoch, decodeTimes: decodeTimes)

                }
            }
            if result != noErr { pending.remove(ticket); fail(result) }
            return result == noErr ? 0 : -1
        }
    }
    private func offerDecoded(_ frame: RTCVideoFrame, epoch: UUID, decodeTimes: (submitMs: Double, callbackMs: Double, ownershipMs: Double)?) {
        // Decoded pixels are independent: one newest pending plus one delivery.
        // No outward callback fence acquisition on the decoder ownership queue.
        deliveryMailbox.lock(); deliveryPending = (frame, epoch, decodeTimes)
        let schedule = !deliveryScheduled; deliveryScheduled = true; deliveryMailbox.unlock()
        if schedule { deliveryQueue.async { [weak self] in self?.deliverDecoded() } }
    }
    private func deliverDecoded() {
        while true {
            lock.lock()
            deliveryMailbox.lock()
            guard let next = deliveryPending else { deliveryScheduled = false; deliveryMailbox.unlock(); lock.unlock(); return }
            deliveryPending = nil; deliveryMailbox.unlock()
            let current = serialized { opened && generation == next.1 }
            if current, let callback {
                if let times = next.2 {
                    timing?.decodedDelivery(rtp: next.0.timeStamp, timeStampNs: next.0.timeStampNs,
                        trace: PhoneDecodeTrace(submitMs: times.submitMs, callbackMs: times.callbackMs,
                                                ownershipMs: times.ownershipMs, deliveryMs: MachClock.nowMs()))
                }
                callback(next.0)
            }
            lock.unlock()
        }
    }
    func implementationName() -> String { configuration.fullColor444 ? "Farside public VideoToolbox HEVC Main444" : "Farside public VideoToolbox HEVC Main" }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

/// Kill switch for the decoder's key-frame request after a swallowed decode error
/// (`defaults write <phone bundle id> PocketDeskHEVCDecodeRecovery -bool NO`, then relaunch the app).
enum HEVCDecodeRecoverySwitch {
    static let defaultsKey = "PocketDeskHEVCDecodeRecovery"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}
