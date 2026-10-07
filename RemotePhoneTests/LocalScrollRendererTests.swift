import CoreVideo
import MetalKit
import WebRTC
import XCTest
@testable import PocketDeskRemote

final class LocalScrollRendererTests: XCTestCase {
    private let whole = CaptureRegion(epoch: 0, x: 0, y: 0, width: 64, height: 64, outputWidth: 64, outputHeight: 64)

    private func identity() -> VideoPresentationIdentity {
        VideoPresentationIdentity(hostRecordID: "host-A", ownerPairID: "grant-A", sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 1)
    }

    private func buffer(rows: (Int) -> UInt8) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<64 { for x in 0..<64 { for c in 0..<4 { base[y * row + x * 4 + c] = c == 3 ? 255 : rows(y) } } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func envelope(_ buffer: CVPixelBuffer, _ id: VideoPresentationIdentity, original: Bool = true) -> VideoFrameEnvelope {
        VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: MachClock.nowMs(), marker: nil, originalSource: original,
            videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
                            geometryEpoch: 1, scopeEpoch: 1, ltrToken: nil, region: whole))
    }

    @MainActor
    func testTheSlideRedrawsOnlyIntoAnIdlePipelineAndTheNextFrameDropsIt() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.metal.isPaused = true
        view.drawRequester = { _ in }
        var acquisitions = 0
        view.drawableAcquirer = { _ in acquisitions += 1; return nil }
        let echo = LocalScrollEchoController(enabled: true)
        echo.setRegion(CGRect(x: 8, y: 8, width: 48, height: 48))
        view.localScroll = echo
        XCTAssertTrue(echo.renderer === view)
        let shown = envelope(try buffer { UInt8($0 * 4) }, id)
        view.mailbox.offer(shown)
        let flight = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))

        echo.scrolled(CGSize(width: 0, height: 4), phase: "began")
        XCTAssertTrue(echo.state.isEchoing)
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 0, "While a draw still owns a drawable the slide waits, so a real frame always finds one free")
        view.mailbox.gpuCompleted(flight.id); view.mailbox.presented(flight.id)
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 1, "An idle pipeline redraws the shown frame with the slide")
        XCTAssertTrue(echo.state.isEchoing, "A redraw of the same frame keeps the slide")

        view.mailbox.offer(envelope(try buffer { UInt8($0 * 4) }, id))
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 2)
        XCTAssertFalse(echo.state.isEchoing, "The Mac's next frame replaces the slide outright")
        XCTAssertEqual(echo.framesBehindSlide, 0, "No slide draw was committed, so no real frame waited behind one")
    }

    @MainActor
    func testASlideNoFrameReplacesIsDroppedAndRedrawnUnshifted() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.metal.isPaused = true
        view.drawRequester = { _ in }
        var acquisitions = 0
        view.drawableAcquirer = { _ in acquisitions += 1; return nil }
        let echo = LocalScrollEchoController(enabled: true)
        echo.setRegion(CGRect(x: 8, y: 8, width: 48, height: 48))
        view.localScroll = echo
        view.mailbox.offer(envelope(try buffer { _ in 90 }, id))
        let flight = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
        view.mailbox.completed(flight.id)
        echo.scrolled(CGSize(width: 0, height: 4), phase: "began", pointer: CGPoint(x: 30, y: 30))
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 1)
        let expired = expectation(description: "stale slide dropped")
        DispatchQueue.main.asyncAfter(deadline: .now() + LocalScrollEcho.staleAfter + 0.1) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
        XCTAssertFalse(echo.state.isEchoing, "With no frame from the Mac the slide must not linger")
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 2, "The shown frame is redrawn without the slide")
        echo.scrolled(.zero, phase: "ended")
        echo.scrolled(CGSize(width: 0, height: 4), phase: "began", pointer: CGPoint(x: 2, y: 2))
        XCTAssertFalse(echo.state.isEchoing, "A gesture outside the reported area does not slide it")
    }

    @MainActor
    func testNoSlideWithTheFlagOffOrNoRegion() throws {
        let id = identity()
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { view.invalidate() }
        view.metal.isPaused = true
        view.drawRequester = { _ in }
        var acquisitions = 0
        view.drawableAcquirer = { _ in acquisitions += 1; return nil }
        view.mailbox.offer(envelope(try buffer { _ in 90 }, id))
        let flight = try XCTUnwrap(view.mailbox.take(holdUntilPresented: true))
        view.mailbox.completed(flight.id)
        let off = LocalScrollEchoController(enabled: false)
        off.setRegion(CGRect(x: 8, y: 8, width: 48, height: 48))
        view.localScroll = off
        off.scrolled(CGSize(width: 0, height: 4), phase: "began")
        view.draw(in: view.metal)
        let unknown = LocalScrollEchoController(enabled: true)
        view.localScroll = unknown
        unknown.scrolled(CGSize(width: 0, height: 4), phase: "began")
        unknown.scrolled(CGSize(width: 0, height: 4), phase: "changed")
        view.draw(in: view.metal)
        XCTAssertEqual(acquisitions, 0, "Nothing is redrawn without the flag or the Mac's region")
        XCTAssertFalse(off.state.isEchoing); XCTAssertFalse(unknown.state.isEchoing)
        XCTAssertFalse(LocalScrollEchoController().enabled, "PocketDeskLocalScroll is off by default")
    }

    func testDecodedFramesThatStopChangingInsideTheRegionEndTheEcho() throws {
        let id = identity()
        let echo = LocalScrollEchoController(enabled: true)
        echo.setRegion(CGRect(x: 8, y: 8, width: 48, height: 48))
        let picture = CGRect(x: 0, y: 0, width: 64, height: 64)
        func observe(_ frame: VideoFrameEnvelope, at now: TimeInterval) throws {
            let pixels = try XCTUnwrap(frame.pixels), geometry = try XCTUnwrap(frame.geometry)
            echo.observe(pixels, geometry: geometry, picture: picture, at: now)
        }
        let striped = envelope(try buffer { $0 % 8 < 4 ? 20 : 230 }, id)
        let samples = try XCTUnwrap(LocalScrollEchoController.luma(try XCTUnwrap(striped.pixels), geometry: try XCTUnwrap(striped.geometry),
                                                                    at: [CGPoint(x: 0.5, y: 1.0 / 128), CGPoint(x: 0.5, y: 5.0 / 64)]))
        XCTAssertEqual(samples, [20, 230], "Reads the decoded rows at the picture points")

        echo.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 1)
        try observe(striped, at: 1.42)
        let moved = envelope(try buffer { ($0 + 2) % 8 < 4 ? 20 : 230 }, id)
        try observe(moved, at: 1.44)
        XCTAssertFalse(echo.state.stopped)
        echo.frameArrived(UUID(), original: true, at: 1.45)
        echo.scrolled(CGSize(width: 0, height: 4), phase: "changed", at: 1.46)
        for t in [1.47, 1.48] { try observe(moved, at: t) }
        XCTAssertFalse(echo.state.stopped)
        try observe(moved, at: 1.49)
        XCTAssertTrue(echo.state.stopped, "Three identical frames while the finger moves: the content is at its end")
        echo.scrolled(CGSize(width: 0, height: 4), phase: "changed", at: 1.5)
        XCTAssertFalse(echo.state.isEchoing)
        echo.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 2)
        XCTAssertTrue(echo.state.isEchoing, "The next gesture echoes again")
    }
}
