import Foundation
import CoreGraphics

/// Phone → Mac on heartbeats (G4, Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the part of the desktop
/// the phone shows, in Mac points, and the phone's viewport in device pixels. Sent only after the
/// Mac advertised `SessionFeature.viewportCapture`, debounced about 120 ms after a gesture settles
/// and on rotation or keyboard changes. `epoch` increases with every change; the Mac echoes it in
/// `CaptureRegion` so the phone knows which frames show which region.
struct ViewportRegion: Codable, Equatable {
    var epoch: UInt64
    /// Visible desktop rect in Mac points, top-left origin, clamped to the display.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// The phone viewport in device pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Phone device pixels per Mac point at the current zoom.
    var zoom: Double

    static let maximumPoints = 20_000.0
    static let pixelRange = 1...16_384
    static let zoomRange = 0.05...20.0

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func validate() throws {
        let values = [x, y, width, height, zoom]
        guard values.allSatisfy({ $0.isFinite }), x >= -Self.maximumPoints, y >= -Self.maximumPoints,
              width > 0, height > 0, width <= Self.maximumPoints, height <= Self.maximumPoints,
              Self.pixelRange.contains(pixelWidth), Self.pixelRange.contains(pixelHeight),
              Self.zoomRange.contains(zoom) else { throw RemoteError.invalidMessage }
    }
}

/// Mac → phone on `capture` status: what the stream covers now. `epoch` 0 means the whole desktop
/// (also what an old Mac implies by never sending one). The rect is in Mac points and includes the
/// pan margin; `outputWidth × outputHeight` is the applied stream size. It stays steady for small
/// pans and zooms, but a large zoom can change it and require an encoder key frame.
struct CaptureRegion: Codable, Equatable {
    var epoch: UInt64
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var outputWidth: Int
    var outputHeight: Int

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isWholeDisplay: Bool { epoch == 0 }

    func validate() throws {
        let values = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite }), x >= -ViewportRegion.maximumPoints, y >= -ViewportRegion.maximumPoints,
              width > 0, height > 0, width <= ViewportRegion.maximumPoints, height <= ViewportRegion.maximumPoints,
              ViewportRegion.pixelRange.contains(outputWidth), ViewportRegion.pixelRange.contains(outputHeight)
        else { throw RemoteError.invalidMessage }
    }
}
