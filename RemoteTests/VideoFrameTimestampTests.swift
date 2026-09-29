import XCTest
import CoreVideo
import WebRTC

/// libwebrtc's low-latency path (the tuned zero playout delay) gives every decoded frame a render
/// time of zero, and a renderer sees that as the frame's timestamp. The phone's Metal video view
/// skips a frame whose timestamp equals the one it last drew, so the phone restamps frames before
/// they reach it (`FrameObserver`); these tests pin down the receiver behaviour that makes it necessary.
final class VideoFrameTimestampTests: XCTestCase {
    @MainActor
    func testTunedReceiverHandsRenderersRepeatedTimestamps() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FARSIDE_TIMESTAMP_TUNING"] == "legacy" { _ = StreamTuning.override(.legacy) }
        let stamps = try await receivedTimestamps()
        print("RECEIVED TIMESTAMPS [\(StreamTuning.current.summary)]: \(stamps.prefix(12))")
        XCTAssertGreaterThanOrEqual(stamps.count, 3, "the loopback receiver decoded frames")
        if StreamTuning.current.playoutDelayMinMs == 0 {
            XCTAssertLessThan(Set(stamps).count, stamps.count,
                              "zero playout delay repeats render timestamps; if this fails, libwebrtc changed and the phone's restamp can be revisited")
        }
    }

    @MainActor
    private func receivedTimestamps() async throws -> [Int64] {
        let host = PeerMedia(isHost: true, servers: [])
        let phone = PeerMedia(isHost: false, servers: [])
        defer { host.close(); phone.close() }
        host.onSignal = { [weak phone] signal in phone?.receive(signal) }
        phone.onSignal = { [weak host] signal in host?.receive(signal) }
        var hostConnected = false, phoneConnected = false
        host.onState = { if $0 == "connected" { hostConnected = true } }
        phone.onState = { if $0 == "connected" { phoneConnected = true } }
        var track: RTCVideoTrack?
        phone.onRemoteVideo = { track = $0 }
        host.offer()
        let deadline = Date().addingTimeInterval(20)
        while !(hostConnected && phoneConnected && track != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let remote = try XCTUnwrap(track, "loopback peers connected")
        let recorder = TimestampRecorder()
        remote.add(recorder)
        defer { remote.remove(recorder) }
        let frame = try Self.grayFrame(width: 640, height: 416)
        for _ in 0..<150 where recorder.values.count < 12 {
            host.pushFrame(frame, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        return recorder.values
    }

    private static func grayFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw XCTSkip("pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, plane == 0 ? 120 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }
}

private final class TimestampRecorder: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Int64] = []

    var values: [Int64] { lock.lock(); defer { lock.unlock() }; return stamps }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); stamps.append(frame.timeStampNs); lock.unlock()
    }
}
