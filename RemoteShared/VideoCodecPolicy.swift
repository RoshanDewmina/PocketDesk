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
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return false }
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        return macroblocks <= 36_864 && macroblocks * 60 <= 2_073_600
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
    func supportedCodecs() -> [RTCVideoCodecInfo] { H264LevelPolicy.codecs(fallback.supportedCodecs()) }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        if info.name == kRTCVideoCodecH264Name { return RTCVideoEncoderH264(codecInfo: info) }
        return fallback.createEncoder(info)
    }
}

final class PocketDeskVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let fallback = RTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [RTCVideoCodecInfo] { H264LevelPolicy.codecs(fallback.supportedCodecs()) }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name == kRTCVideoCodecH264Name { return RTCVideoDecoderH264() }
        return fallback.createDecoder(info)
    }
}
