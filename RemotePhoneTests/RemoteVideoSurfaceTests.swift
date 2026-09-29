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
    func testM153CompletedStampAdvancesOnlyAfterTheMetalDelegateDraws() throws {
        let (view, metal, window) = try makeVideoView()
        defer { window.isHidden = true }
        XCTAssertTrue(view.responds(to: NSSelectorFromString(VideoPresentationProbe.drawnStampKey)),
                      "WebRTC M153 must expose the compatibility stamp")
        let renderer = RestampingRenderer(target: view)
        let frame = RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0)
        let stamp = try XCTUnwrap(renderer.renderFrame(frame, marker: nil))
        XCTAssertNotEqual(Self.lastDrawnStamp(of: view), stamp,
                          "handing off a candidate is not evidence that the delegate drew it")
        metal.draw()
        XCTAssertEqual(Self.lastDrawnStamp(of: view), stamp,
                       "M153 records the exact stamp only after its Metal draw path completes")
    }

    @MainActor
    func testRendererRegistersTheRestampBeforeRenderReturnsAndSkipsDisabledView() throws {
        let view = RTCMTLVideoView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let renderer = RestampingRenderer(target: view)
        let frame = RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0)
        var registeredStamp: Int64?
        let returnedStamp = renderer.renderFrame(frame, beforeForward: { forwarded in
            registeredStamp = forwarded.stampNs
        })
        XCTAssertEqual(registeredStamp, returnedStamp,
                       "the exact identity is registered synchronously before the handoff returns")

        view.isEnabled = false
        registeredStamp = nil
        XCTAssertNil(renderer.renderFrame(frame, beforeForward: { registeredStamp = $0.stampNs }))
        XCTAssertNil(registeredStamp, "a view that rejects rendering does not create false pressure")
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
    func testRestampingRendererRemembersTheLastSixteenMarkers() throws {
        let view = RTCMTLVideoView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let renderer = RestampingRenderer(target: view)
        let frame = RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0)
        renderer.renderFrame(frame)
        XCTAssertNil(renderer.newestMarker, "frames forwarded without statistics are not remembered")
        func marker(_ index: Int) -> BenchMarker? {
            index % 5 == 4 ? nil : BenchMarker(timeMs: UInt32(1_000 + index), chartSeed: 3, flash: false, motion: true)
        }
        var stamps: [Int64] = []
        for index in 0..<20 {
            stamps.append(try XCTUnwrap(renderer.renderFrame(frame, marker: marker(index))))
        }
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count)
        let forgotten = stamps.count - RestampingRenderer.rememberedFrames
        for (index, stamp) in stamps.enumerated() {
            let remembered = renderer.forwardedFrame(forStamp: stamp)
            if index < forgotten {
                XCTAssertNil(remembered, "frame \(index) is older than the ring")
            } else {
                XCTAssertEqual(remembered?.marker, marker(index), "frame \(index)")
                XCTAssertGreaterThan(remembered?.arrivalMs ?? 0, 0)
            }
        }
        XCTAssertNotNil(renderer.forwardedFrame(forStamp: stamps[19]))
        XCTAssertNil(renderer.marker(forStamp: stamps[19]), "a frame without a readable marker is remembered as nil")
        XCTAssertNil(renderer.newestMarker)
        XCTAssertEqual(renderer.marker(forStamp: stamps[18]), marker(18))
        renderer.forgetMarkers()
        XCTAssertNil(renderer.forwardedFrame(forStamp: stamps[18]))
    }

    @MainActor
    func testObserverReadsTheMarkerOnlyWithStreamStatistics() throws {
        let view = RTCMTLVideoView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let observer = FrameObserver(onFrame: {})
        observer.view = view
        let marker = BenchMarker(timeMs: 77_777, chartSeed: 0x2ab, flash: true, motion: false)
        let marked = RTCCVPixelBuffer(pixelBuffer: try Self.markedPixelBuffer(marker))
        observer.renderFrame(RTCVideoFrame(buffer: marked, rotation: ._0, timeStampNs: 0))
        XCTAssertNil(observer.forward.newestMarker, "statistics off: nothing is read or remembered")
        observer.readsMarkers = true
        observer.renderFrame(RTCVideoFrame(buffer: marked, rotation: ._0, timeStampNs: 0))
        XCTAssertEqual(observer.forward.newestMarker, marker, "the strip is read from the decoded luma plane")
        observer.renderFrame(RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0))
        XCTAssertNil(observer.forward.newestMarker, "a frame without a marker is recorded as none")
        observer.readsMarkers = false
        XCTAssertNil(observer.forward.newestMarker)
    }

    @MainActor
    func testPresentedFrameCarriesTheMarkerOfTheFrameTheViewDrew() throws {
        let (view, metal, window) = try makeVideoView()
        defer { window.isHidden = true }
        let probe = try XCTUnwrap(VideoPresentationProbe.install(on: view), "The probe finds the MTKView")
        defer { probe.uninstall() }
        let counters = StreamCounters()
        probe.counters = counters
        var fetches = 0
        probe.drawableProvider = { metalView in
            fetches += 1
            return metalView.currentDrawable
        }
        let observer = FrameObserver(onFrame: {})
        observer.view = view
        observer.presentation = probe
        observer.setSize(CGSize(width: 432, height: 270))

        // WebRTC creates its Metal renderer (and so a device and drawables) on the first drawn frame.
        observer.renderFrame(RTCVideoFrame(buffer: try Self.pixelBuffer(), rotation: ._0, timeStampNs: 0))
        metal.draw()
        XCTAssertNotNil(metal.device, "The renderer started")
        XCTAssertEqual(fetches, 0, "Without Stream statistics no drawable is fetched")

        observer.readsMarkers = true
        metal.draw()
        XCTAssertEqual(fetches, 0, "No drawable is fetched when no decoded frame is pending")

        let marker = BenchMarker(timeMs: 4_321, chartSeed: 0, flash: false, motion: true)
        let marked = RTCCVPixelBuffer(pixelBuffer: try Self.markedPixelBuffer(marker))
        observer.renderFrame(RTCVideoFrame(buffer: marked, rotation: ._0, timeStampNs: 0))
        metal.draw()
        XCTAssertEqual(fetches, 1, "One drawable for the one new frame")
        XCTAssertEqual(observer.forward.marker(forStamp: Self.lastDrawnStamp(of: view)), marker,
                       "The stamp the view drew maps back to the frame's marker")
        metal.draw()
        XCTAssertEqual(fetches, 1, "Redrawing the same frame fetches nothing")

        #if !targetEnvironment(simulator)
        // On a device the frame is reported from the drawable's presented handler, asynchronously.
        let deadline = Date().addingTimeInterval(2)
        while counters.drain(inputBufferedBytes: nil).markerFrames == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        #endif
        // The simulator's Metal has no presented handler, so the probe reports the frame at draw time.
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.markerFrames, 1, "The drawn frame reached the counters with its marker")
        XCTAssertEqual(snapshot.markerDistinct, 1)
        XCTAssertEqual(snapshot.presentedFrames, 2, "Draw-call accounting is unchanged")
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

    /// An NV12 frame whose luma plane carries the bench strip, drawn by the shared renderer.
    private static func markedPixelBuffer(_ marker: BenchMarker, width: Int = 432, height: Int = 270) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw XCTSkip("pixel buffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 120 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        // The renderer expects a flipped (top-left) context.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        BenchMarkerRenderer.draw(marker, layout: BenchMarker.layout(width: Double(width), height: Double(height)), in: context)
        return buffer
    }
}
