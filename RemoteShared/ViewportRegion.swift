import Foundation
import CoreGraphics

/// Phone → Mac on heartbeats (G4, Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the part of the desktop
/// the phone shows, in Mac points, and the phone's viewport in device pixels. Sent only after the
/// Mac advertised `SessionFeature.viewportCapture`; during a gesture only when the stream no longer
/// covers the view (`ViewportReporter`). `epoch` increases with every change; the Mac echoes it in
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

/// The b7-scroll package (2 Oct 2026: crop-gain and keep-band rules on the Mac; placing frames by their
/// own region, the View-mode zoom dead band and the widening cap on the phone) ships OFF until Roshan's
/// device A/B shows it at least as stable as viewport capture off. `defaults write <bundle id>
/// PocketDeskScrollFixes -bool YES` on each side, then relaunch, turns the whole package on; each part
/// keeps its own key, read only when this one is on.
enum ScrollFixesSwitch {
    static let defaultsKey = "PocketDeskScrollFixes"
    // NSArgumentDomain stores launch overrides as strings (YES/NO), unlike defaults write.
    // Foundation's Boolean accessor handles both; absent remains off.
    static func enabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
    static let isOn = enabled()
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
