import Foundation
import VideoToolbox
import CoreMedia
func dump(_ name: String, codec: CMVideoCodecType, ll: Bool, keys: [String]) {
    var id: CFString?; var dict: CFDictionary?
    let spec: [CFString: Any] = ll ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] : [:]
    let st = VTCopySupportedPropertyDictionaryForEncoder(width: 2940, height: 1912, codecType: codec, encoderSpecification: spec as CFDictionary, encoderIDOut: &id, supportedPropertiesOut: &dict)
    print("== \(name) LL=\(ll) status=\(st) encoderID=\(id as String? ?? "nil")")
    guard let d = dict as? [String: Any] else { return }
    for k in keys.filter({ d[$0] != nil }) { print("  \(k): \(d[k]!)") }
}
let keys = ["NumberOfSlices","QualityMode","PerceptualQualityOptimization","MaxFrameDelayCount","MaxAllowedFrameQP","MinAllowedFrameQP","ReferenceBufferCount","BaseLayerFrameRateFraction","EnableLTR","Depth","AverageBitRateIntraLayer","SliceQP","SliceMaxQP","PrioritizeEncodingSpeedOverQuality","SpatialAdaptiveQPLevel","RelaxAverageBitRateTarget","ConstantQualityFactor","Quality","AllowTemporalCompression","MaxKeyFrameInterval","DataRateLimits"]
dump("H264", codec: kCMVideoCodecType_H264, ll: false, keys: keys)
dump("H264", codec: kCMVideoCodecType_H264, ll: true, keys: keys)
dump("HEVC", codec: kCMVideoCodecType_HEVC, ll: false, keys: keys)
dump("HEVC", codec: kCMVideoCodecType_HEVC, ll: true, keys: keys)
