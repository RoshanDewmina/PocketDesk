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
    /// Nil unless the phone asked for text clarity, the encoder accepted the QP setter and the still QP is tighter than the session's
    /// (so nil for H.264 at the default ceiling of 26); true while the still-picture floor is applied.
    var textClarityActive: Bool? = nil
    /// Owned encoder only: optional session settings and whether VideoToolbox accepted them.
    var options: String? = nil
    func validate() throws {
        guard maximumQPBound.map({ (1...51).contains($0) }) ?? true, (options?.count ?? 0) <= 160,
              path != .compatibility || (maximumQPBound == nil && !lowLatencyRequested && !hardwareRequired && textClarityActive == nil && options == nil),
              path != .ownedVideoToolbox || (hardwareRequired && hardwareReported != false) else {
            throw RemoteError.invalidMessage
        }
    }
    var summary: String {
        let qp = maximumQPBound.map(String.init) ?? "unsupported"
        let hardware = hardwareReported.map { $0 ? "reported hardware" : "reported software" } ?? "hardware report unavailable"
        let clarity = textClarityActive.map { $0 ? " · text clarity active" : " · text clarity ready" } ?? ""
        return "encoder path \(path.rawValue) · QP bound \(qp) · low-latency request \(lowLatencyRequested) · hardware required \(hardwareRequired) · \(hardware)" + clarity
            + (options.map { " · " + $0 } ?? "")
    }
}
