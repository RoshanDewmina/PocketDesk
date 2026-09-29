import XCTest
import MetalKit
import WebRTC
@testable import PocketDeskRemote

/// With the tuned zero playout delay, libwebrtc hands renderers frames stamped 0 (see
/// `VideoFrameTimestampTests` in RemoteCoreTests). These tests drive the shipped RTCMTLVideoView.
final class RemoteVideoSurfaceTests: XCTestCase {
    @MainActor
    func testMetalViewIgnoresFramesThatRepeatItsLastTimestamp() throws {
        let (view, metal, window) = try makeVideoView()
        defer { window.isHidden = true }
        view.renderFrame(RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0))
        metal.draw()
        XCTAssertNil(metal.device, "RTCMTLVideoView treats a frame stamped 0 as already drawn and never sets up its renderer")
        view.renderFrame(RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 1))
        metal.draw()
        XCTAssertNotNil(metal.device, "A new timestamp is drawn")
    }

    @MainActor
    func testFramesStampedZeroAreDrawnThroughTheSurfaceObserver() throws {
        let (view, metal, window) = try makeVideoView()
        defer { window.isHidden = true }
        var arrivals = 0
        let observer = FrameObserver(onFrame: { arrivals += 1 })
        observer.view = view
        let buffer = try Self.pixelBuffer()
        observer.setSize(CGSize(width: 64, height: 48))
        var drawn: [Int64] = []
        for _ in 0..<3 {
            observer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 0))
            metal.draw()
            drawn.append(Self.lastDrawnStamp(of: view))
        }
        XCTAssertNotNil(metal.device, "The first frame stamped 0 reaches the Metal renderer")
        XCTAssertTrue(drawn.allSatisfy { $0 > 0 }, "Every frame is drawn: \(drawn)")
        XCTAssertEqual(Set(drawn).count, drawn.count, "Each frame gets its own timestamp: \(drawn)")
        XCTAssertEqual(drawn, drawn.sorted(), "Timestamps only increase")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThanOrEqual(arrivals, 1, "Arrivals are still reported")
    }

    @MainActor
    func testRendererStartKeepsTheRefreshRateThePresentationChose() throws {
        try XCTSkipUnless(StreamTuning.current.presentAtDisplayMaximum, "Only the tuned presentation chooses a refresh rate")
        let (view, metal, window) = try makeVideoView()
        defer { window.isHidden = true }
        let probe = try XCTUnwrap(VideoPresentationProbe.install(on: view), "The probe finds the MTKView")
        defer { probe.uninstall() }
        let chosen = metal.preferredFramesPerSecond
        let observer = FrameObserver(onFrame: {})
        observer.view = view
        observer.presentation = probe
        observer.renderFrame(RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0))
        metal.draw()
        XCTAssertNotNil(metal.device, "The renderer started")
        XCTAssertEqual(metal.preferredFramesPerSecond, chosen, "WebRTC's renderer setup must not lower the refresh rate")
    }

    @MainActor
    private func makeVideoView() throws -> (RTCMTLVideoView, MTKView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let view = RTCMTLVideoView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        let metal = try XCTUnwrap(VideoPresentationProbe.findMetalView(in: view), "RTCMTLVideoView hosts an MTKView")
        XCTAssertNil(metal.device, "Precondition: the renderer is created on the first drawn frame")
        return (view, metal, window)
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
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 200 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RTCCVPixelBuffer(pixelBuffer: buffer)
    }
}
