import Compression
import CoreMedia
import Foundation
import VideoToolbox

/// A conservative, process-cached capability gate for the native H.264 Level 5.2 path.
/// One successful frame proves format/decode compatibility, not sustained 4K60 performance.
///
/// A positive result is also cached in UserDefaults, keyed by OS build and hardware model, so later
/// launches skip the probe; a failed or timed-out probe is never cached and is retried next launch.
/// `warmUp()` runs the probe on a background queue at launch so the first factory rarely waits.
enum NativeCodecCapability {
    enum Outcome: Equatable {
        case simulator
        case noHardwareDecode
        case cached
        case probed(milliseconds: Int)
        case probeFailed
        case timedOut

        var description: String {
            switch self {
            case .simulator: return "simulator: level 3.1"
            case .noHardwareDecode: return "no hardware H.264 decode: level 3.1"
            case .cached: return "hardware level 5.2 (cached)"
            case .probed(let ms): return "hardware level 5.2 (probed in \(ms) ms)"
            case .probeFailed: return "probe failed: level 3.1 this launch"
            case .timedOut: return "probe timed out: level 3.1 this launch"
            }
        }
    }

    private static let state = ProbeState()
    static var outcome: Outcome? { state.outcome }
    static var outcomeDescription: String { outcome?.description ?? "not probed yet" }
    static let probeTimeout: DispatchTimeInterval = .seconds(3)

    static let supportsLevel52: Bool = {
        #if targetEnvironment(simulator)
        state.outcome = .simulator
        return false
        #else
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else {
            state.outcome = .noHardwareDecode
            return false
        }
        if cachedResult() == true {
            state.outcome = .cached
            return true
        }
        let started = MachClock.nowMs()
        let outcome = ProbeOutcome()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let result = runProbe()
            outcome.set(result)
            // A late success still helps the next launch.
            if result { storeResult(true) }
            group.leave()
        }
        guard group.wait(timeout: .now() + probeTimeout) == .success else {
            state.outcome = .timedOut
            return false
        }
        let value = outcome.value
        state.outcome = value ? .probed(milliseconds: Int((MachClock.nowMs() - started).rounded())) : .probeFailed
        return value
        #endif
    }()

    /// Evaluates the probe off the calling thread so a later factory creation finds it done.
    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = supportsLevel52 }
    }

    static var cacheDefaultsKey: String { "PocketDeskLevel52Probe." + systemAndModel }

    static func cachedResult(defaults: UserDefaults = .standard, key: String = cacheDefaultsKey) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    /// Only a positive result is stored; negatives are retried on the next launch.
    static func storeResult(_ value: Bool, defaults: UserDefaults = .standard, key: String = cacheDefaultsKey) {
        guard value else { return }
        defaults.set(true, forKey: key)
    }

    static var systemAndModel: String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion).\(machine)"
    }

    /// Exposed to focused tests so the baked sample's advertised profile and dimensions
    /// are independently checked by CoreMedia, rather than trusting its filename.
    static func fixtureDescription() -> CMVideoFormatDescription? {
        guard let units = fixtureNALUnits(),
              let sps = units.first(where: { $0.first.map { $0 & 0x1f == 7 } ?? false }),
              let pps = units.first(where: { $0.first.map { $0 & 0x1f == 8 } ?? false }),
              sps.count >= 4, sps[1] == 0x64, sps[3] == 0x34 else { return nil }
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                let pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description,
              CMVideoFormatDescriptionGetDimensions(description).width == 3840,
              CMVideoFormatDescriptionGetDimensions(description).height == 2160 else { return nil }
        return description
    }

    private static func runProbe() -> Bool {
        guard let description = fixtureDescription(),
              let units = fixtureNALUnits(),
              let sample = makeSample(description: description, units: units) else { return false }

        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
        var optionalSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                           formatDescription: description,
                                           decoderSpecification: specification,
                                           imageBufferAttributes: nil,
                                           outputCallback: nil,
                                           decompressionSessionOut: &optionalSession) == noErr,
              let session = optionalSession else { return false }
        defer { VTDecompressionSessionInvalidate(session) }

        var gotFrame = false
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { decodeStatus, flags, imageBuffer, _, _ in
            guard decodeStatus == noErr, !flags.contains(.frameDropped), let imageBuffer else { return }
            gotFrame = CVPixelBufferGetWidth(imageBuffer) == 3840 && CVPixelBufferGetHeight(imageBuffer) == 2160
        }
        guard status == noErr, gotFrame else { return false }

        var property: CFTypeRef?
        let propertyStatus = withUnsafeMutablePointer(to: &property) { pointer in
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard propertyStatus == noErr,
              let property else { return false }
        return CFGetTypeID(property) == CFBooleanGetTypeID() && CFEqual(property, kCFBooleanTrue)
    }

    private static func makeSample(description: CMVideoFormatDescription,
                                   units: [[UInt8]]) -> CMSampleBuffer? {
        let slices = units.filter { $0.first.map { $0 & 0x1f == 5 } ?? false }
        guard !slices.isEmpty else { return nil }
        var bytes: [UInt8] = []
        for slice in slices {
            var length = UInt32(slice.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: slice)
        }
        var optionalBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: bytes.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: bytes.count,
                                                 flags: 0,
                                                 blockBufferOut: &optionalBlock) == kCMBlockBufferNoErr,
              let block = optionalBlock else { return nil }
        let copyStatus = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = bytes.count
        var optionalSample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: description, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &optionalSample) == noErr else { return nil }
        return optionalSample
    }

    private static func fixtureNALUnits() -> [[UInt8]]? {
        // One black 3840x2160 High@5.2 IDR, generated with libx264; SEI removed.
        // Raw DEFLATE for COMPRESSION_ZLIB keeps the embedded fixture small.
        // Decompressed data is capped at 1603 bytes.
        let compressed = "Y2BgYExPETBZs4O9gaO2oYOBgZmBA0QIKDAApTLe8Z8GUqkdLSz7n/xnffDvi3V8+eZ/v4/XZU51Kr6p96c0f8K7uOOxh0BaMNF/SZtzex5c/cteMAFFXPYAjG3QAGPFwsQYNeAKmXfAmAJwdZFwWSYLGJP7AYwVh5BVgDEFsTtuFI2iUTSKRhEliF0UAA=="
        guard let payload = Data(base64Encoded: compressed) else { return nil }
        let decodedCapacity = 1603
        var bytes = [UInt8](repeating: 0, count: decodedCapacity)
        let decoded = payload.withUnsafeBytes { source in
            bytes.withUnsafeMutableBytes { destination in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, decodedCapacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == decodedCapacity else { return nil }
        var units: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            guard let marker = startCode(in: bytes, from: offset) else { return nil }
            let start = marker.offset + marker.length
            let end = startCode(in: bytes, from: start)?.offset ?? bytes.count
            guard start < end else { return nil }
            units.append(Array(bytes[start..<end]))
            offset = end
        }
        guard units.count == 3 else { return nil }
        return units
    }

    private static func startCode(in bytes: [UInt8], from offset: Int) -> (offset: Int, length: Int)? {
        guard offset < bytes.count else { return nil }
        for index in offset..<bytes.count where index + 2 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    return (index, 4)
                }
                if bytes[index + 2] == 1 { return (index, 3) }
            }
        }
        return nil
    }
}

private final class ProbeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ value: Bool) { lock.lock(); result = value; lock.unlock() }
}

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeCodecCapability.Outcome?
    var outcome: NativeCodecCapability.Outcome? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
