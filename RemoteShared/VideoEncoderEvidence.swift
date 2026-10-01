import Foundation

/// Encoder-selected facts, separate from WebRTC's implementation label and QP statistics.
/// An accepted public QP-bound setter is not a measured bitstream QP or legibility score.
struct VideoEncoderEvidence: Codable, Equatable {
    enum Path: String, Codable { case ownedVideoToolbox, compatibility }
    let path: Path
    let maximumQPBound: Int?
    let lowLatencyRequested: Bool
    let hardwareRequired: Bool
    let hardwareReported: Bool?
    /// Nil unless the phone asked for text clarity and the encoder accepted the QP setter; true while the still-picture floor is applied.
    var textClarityActive: Bool? = nil
    func validate() throws {
        guard maximumQPBound.map({ (1...51).contains($0) }) ?? true,
              path != .compatibility || (maximumQPBound == nil && !lowLatencyRequested && !hardwareRequired && textClarityActive == nil),
              path != .ownedVideoToolbox || (hardwareRequired && hardwareReported != false) else {
            throw RemoteError.invalidMessage
        }
    }
    var summary: String {
        let qp = maximumQPBound.map(String.init) ?? "unsupported"
        let hardware = hardwareReported.map { $0 ? "reported hardware" : "reported software" } ?? "hardware report unavailable"
        let clarity = textClarityActive.map { $0 ? " · text clarity active" : " · text clarity ready" } ?? ""
        return "encoder path \(path.rawValue) · QP bound \(qp) · low-latency request \(lowLatencyRequested) · hardware required \(hardwareRequired) · \(hardware)" + clarity
    }
}
