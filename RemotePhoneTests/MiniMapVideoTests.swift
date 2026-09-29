import XCTest
import MetalKit
import WebRTC
@testable import PocketDeskRemote

/// The mini map's second picture must go through `RestampingRenderer` like the main one: tuned
/// streams stamp every frame 0 and RTCMTLVideoView skips a repeated timestamp, so a view added
/// straight to the track would stay black (see `RemoteVideoSurfaceTests`).
final class MiniMapVideoTests: XCTestCase {
    @MainActor
    func testFramesStampedZeroReachTheMiniMapViewAndStopAfterDisconnect() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 150, height: 94))
        defer { window.isHidden = true }
        let view = RTCMTLVideoView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        let metal = try XCTUnwrap(VideoPresentationProbe.findMetalView(in: view))
        XCTAssertNil(metal.device, "Precondition: nothing drawn yet")

        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "minimap-test")
        let coordinator = MiniMapVideo.Coordinator()
        coordinator.connect(view, to: track)
        XCTAssertTrue(coordinator.renderer.target === view, "The track feeds the restamping renderer, not the view")
        XCTAssertTrue(coordinator.track === track)

        let buffer = try Self.pixelBuffer()
        coordinator.renderer.setSize(CGSize(width: 64, height: 48))
        var drawn: [Int64] = []
        for _ in 0..<3 {
            coordinator.renderer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 0))
            metal.draw()
            drawn.append(Self.lastDrawnStamp(of: view))
        }
        XCTAssertNotNil(metal.device, "A frame stamped 0 is drawn in the mini map")
        XCTAssertTrue(drawn.allSatisfy { $0 > 0 }, "\(drawn)")
        XCTAssertEqual(Set(drawn).count, drawn.count, "Each frame gets its own timestamp: \(drawn)")
        XCTAssertEqual(drawn, drawn.sorted())

        coordinator.disconnect()
        XCTAssertNil(coordinator.renderer.target)
        XCTAssertNil(coordinator.track)
        let before = Self.lastDrawnStamp(of: view)
        coordinator.renderer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 0))
        metal.draw()
        XCTAssertEqual(Self.lastDrawnStamp(of: view), before, "A hidden mini map draws nothing")
    }

    private static func lastDrawnStamp(of view: RTCMTLVideoView) -> Int64 {
        guard view.responds(to: NSSelectorFromString("lastFrameTimeNs")) else { return -1 }
        return (view.value(forKey: "lastFrameTimeNs") as? NSNumber)?.int64Value ?? -1
    }

    private static func pixelBuffer() throws -> RTCCVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw XCTSkip("pixel buffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 90 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RTCCVPixelBuffer(pixelBuffer: buffer)
    }
}
