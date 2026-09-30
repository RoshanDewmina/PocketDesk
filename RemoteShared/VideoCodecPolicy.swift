import Foundation
import WebRTC

/// Desktop frames exceed the default WebRTC level 3.1 camera envelope.
/// Retain profile/packetization negotiation while allowing the native 4K60 envelope.
enum H264LevelPolicy {
    static func raisingLevel(_ parameters: [String: String]) -> [String: String] {
        guard let value = parameters["profile-level-id"], value.count == 6,
              let packed = UInt32(value, radix: 16) else { return parameters }
        var result = parameters
        result["profile-level-id"] = String(format: "%06x", (packed & 0xffff00) | max(packed & 0xff, 0x34))
        return result
    }

    static func fitsAt60FPS(width: Int, height: Int) -> Bool {
        fits(width: width, height: height, fps: 60)
    }

    /// H.264 level 5.2: at most 36,864 macroblocks per frame and 2,073,600 per second.
    static func fits(width: Int, height: Int, fps: Int) -> Bool {
        guard width > 0, height > 0, width <= 4096, height <= 4096, fps > 0 else { return false }
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        return macroblocks <= 36_864 && macroblocks * fps <= 2_073_600
    }

    static func codecs(_ values: [RTCVideoCodecInfo]) -> [RTCVideoCodecInfo] {
        let h264 = values.filter { $0.name == kRTCVideoCodecH264Name }.map {
            RTCVideoCodecInfo(name: $0.name, parameters: raisingLevel($0.parameters))
        }
        return h264 + values.filter { $0.name != kRTCVideoCodecH264Name }
    }
}

final class PocketDeskVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let fallback = RTCDefaultVideoEncoderFactory()
    private let counters: StreamCounters?
    private let frameTiming: HostFrameTimingLog?
    private let hevc: Bool
    private let onHEVCFailure: (() -> Void)?
    private let videoFeedback: VideoFeedbackContext?
    private let preferLTR: Bool
    init(hevc: Bool = false, counters: StreamCounters? = nil, frameTiming: HostFrameTimingLog? = nil, onHEVCFailure: (() -> Void)? = nil, videoFeedback: VideoFeedbackContext? = nil, preferLTR: Bool = false) {
        self.preferLTR = preferLTR; self.videoFeedback = videoFeedback; self.onHEVCFailure = onHEVCFailure; self.hevc = hevc; self.counters = counters; self.frameTiming = frameTiming
        super.init()
    }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        let codecs = NativeCodecCapability.supportsLevel52 ? H264LevelPolicy.codecs(fallback.supportedCodecs()) : fallback.supportedCodecs()
        let high = codecs.filter { $0.name == kRTCVideoCodecH264Name && OwnedVTConfiguration(parameters: $0.parameters)?.lowLatency == true }
        let ordered = preferLTR ? high + codecs.filter { value in !high.contains { $0.name == value.name && $0.parameters == value.parameters } } : codecs
        return (hevc ? [OwnedHEVCConfiguration.codecInfo] : []) + ordered
    }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        if hevc, info.name == "H265", let configuration = OwnedHEVCConfiguration(parameters: info.parameters) {
            return ResilientVTEncoder(configuration: configuration, counters: counters, frameTiming: frameTiming, onFailure: onHEVCFailure, videoFeedback: videoFeedback)
        }
        if info.name == kRTCVideoCodecH264Name {
            #if os(macOS)
            if !VideoEncoderCompatibility.isOn, let configuration = OwnedVTConfiguration(parameters: info.parameters) {
                return ResilientVTEncoder(configuration: configuration, codecInfo: info, counters: counters, frameTiming: frameTiming, videoFeedback: videoFeedback)
            }
            #endif
            return StreamTuning.current.encoderRestart ? DesktopH264Encoder(codecInfo: info, counters: counters, frameTiming: frameTiming) : RTCVideoEncoderH264(codecInfo: info)
        }
        return fallback.createEncoder(info)
    }
}

final class PocketDeskVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let fallback = RTCDefaultVideoDecoderFactory()
    private let frameTiming: PhoneFrameTimingLog?
    private let hevc: Bool
    private let onHEVCFailure: (() -> Void)?
    private let videoFeedback: VideoFeedbackContext?
    init(hevc: Bool = false, frameTiming: PhoneFrameTimingLog? = nil, onHEVCFailure: (() -> Void)? = nil, videoFeedback: VideoFeedbackContext? = nil) { self.videoFeedback = videoFeedback; self.onHEVCFailure = onHEVCFailure; self.hevc = hevc; self.frameTiming = frameTiming; super.init() }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        (hevc ? [OwnedHEVCConfiguration.codecInfo] : []) + (NativeCodecCapability.supportsLevel52 ? H264LevelPolicy.codecs(fallback.supportedCodecs()) : fallback.supportedCodecs())
    }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if hevc, info.name == "H265", let configuration = OwnedHEVCConfiguration(parameters: info.parameters) { let decoder = OwnedHEVCDecoder(configuration: configuration, timing: frameTiming, onFailure: onHEVCFailure); return videoFeedback.map { VideoFeedbackDecoder(inner: decoder, context: $0, hevc: true) } ?? decoder }
        if info.name == kRTCVideoCodecH264Name {
            let decoder: any RTCVideoDecoder = frameTiming.map { TimedH264Decoder(log: $0) } ?? RTCVideoDecoderH264()
            return videoFeedback.map { VideoFeedbackDecoder(inner: decoder, context: $0) } ?? decoder
        }
        return fallback.createDecoder(info)
    }
}

struct H264FrameBudget: Equatable {
    let frameMacroblocks: Int
    let macroblocksPerSecond: Int
    var maximumEdge: Int = 4096

    static func level(_ level: UInt8) -> H264FrameBudget {
        let values: [UInt8: (Int, Int)] = [
            10: (99, 1485), 11: (396, 3000), 12: (396, 6000), 13: (396, 11880),
            20: (396, 11880), 21: (792, 19800), 22: (1620, 20250), 30: (1620, 40500),
            31: (3600, 108000), 32: (5120, 216000), 40: (8192, 245760),
            41: (8192, 245760), 42: (8704, 522240), 50: (22080, 589824),
            51: (36864, 983040), 52: (36864, 2073600)
        ]
        let value = values[level] ?? values[31]!
        return H264FrameBudget(frameMacroblocks: value.0, macroblocksPerSecond: value.1)
    }

    /// Use the first negotiated video codec, not an unrelated fmtp line in the SDP.
    static func receivingLimit(sdp: String) -> H264FrameBudget? {
        let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return nil }
        let section = lines[(start + 1)...].prefix(while: { !$0.hasPrefix("m=") })
        let fields = lines[start].split(separator: " ")
        guard fields.count > 3 else { return nil }
        let payload = String(fields[3])
        if section.contains(where: { $0.lowercased().hasPrefix("a=rtpmap:\(payload) h265/") }) {
            let raw = section.first(where: { $0.hasPrefix("a=fmtp:\(payload) ") }) ?? ""
            let parameterText = raw.split(separator: " ", maxSplits: 1).dropFirst().first ?? ""
            var parameters: [String: String] = [:]
            for entry in parameterText.split(separator: ";") {
                let pair = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { parameters[pair[0]] = pair[1] }
            }
            guard let configuration = OwnedHEVCConfiguration(parameters: parameters) else { return nil }
            let samples = configuration.level < 150 ? 2_228_224 : 8_912_896
            let sampleRate = [UInt8(120): 66_846_720, 123: 133_693_440, 150: 267_386_880, 153: 534_773_760][configuration.level]!
            return H264FrameBudget(frameMacroblocks: samples / 256, macroblocksPerSecond: sampleRate / 256)
        }
        guard section.contains(where: { $0.lowercased().hasPrefix("a=rtpmap:\(payload) h264/") }) else { return nil }
        let parameters = section.first(where: { $0.hasPrefix("a=fmtp:\(payload) ") }) ?? ""
        let profile = parameters.split(separator: ";").compactMap { part -> String? in
            let text = String(part).trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: "profile-level-id=") else { return nil }
            return String(text[range.upperBound...])
        }.first
        guard let profile, profile.count == 6, let packed = UInt32(profile, radix: 16) else { return level(31) }
        return level(UInt8(packed & 0xff))
    }

    func fitted(width: Int, height: Int, fps: Int = 60) -> (width: Int, height: Int) {
        guard width >= 2, height >= 2, width <= 16384, height <= 16384, fps > 0 else { return (2, 2) }
        let budget = min(frameMacroblocks, macroblocksPerSecond / fps)
        let inputMB = ((width + 15) / 16) * ((height + 15) / 16)
        let ratio = min(1, Double(maximumEdge) / Double(max(width, height)), sqrt(Double(budget) / Double(inputMB)))
        var w = max(2, Int(Double(width) * ratio) & ~1)
        var h = max(2, Int(Double(height) * ratio) & ~1)
        while ((w + 15) / 16) * ((h + 15) / 16) > budget, w > 2, h > 2 {
            w -= 2
            h = max(2, Int(Double(w) * Double(height) / Double(width)) & ~1)
        }
        return (w, h)
    }
}
