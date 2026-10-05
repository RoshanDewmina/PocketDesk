import Foundation

struct VirtualDisplayResizeBegin: Codable, Equatable, Sendable {
    var version = 1
    let token: String
    let display: UInt32
    let fromEpoch: UInt64
    let scopeEpoch: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
    func validate() throws {
        guard version == 1, InputCausalEnvelope.validID(token), display > 0, fromEpoch > 0, scopeEpoch > 0,
              (128...VirtualDisplaySpecification.maximumAxisPixels).contains(pixelWidth),
              (128...VirtualDisplaySpecification.maximumAxisPixels).contains(pixelHeight),
              pixelWidth % 2 == 0, pixelHeight % 2 == 0,
              pixelWidth * pixelHeight <= VirtualDisplaySpecification.maximumPixels else { throw RemoteError.invalidMessage }
    }
}
