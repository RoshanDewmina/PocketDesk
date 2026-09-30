import XCTest
import WebRTC
import CoreVideo

final class NativePacketRepairTransportTests: XCTestCase {
    @MainActor
    func testActualRelayPolicyNegotiatesRepairAndDirectPolicyRemovesItWithoutRelabellingVideo() async throws {
        // Dedicated XCTest process: global public trials precede the first factory.
        PacketRepairPreferences.overrideForTesting = true
        let host = PeerMedia(isHost: true, servers: [], hevc: false)
        let phone = PeerMedia(isHost: false, servers: [], hevc: false)
        defer { host.close(); phone.close() }
        host.routeOverrideForTesting = "Relay" // Synthetic policy input, transport remains genuine loopback.
        var offer = "", answer = "", remote: RTCVideoTrack?, connected = false
        host.onSignal = { [weak phone] signal in if signal.kind == "offer" { offer = signal.sdp ?? "" }; phone?.receive(signal) }
        phone.onSignal = { [weak host] signal in if signal.kind == "answer" { answer = signal.sdp ?? "" }; host?.receive(signal) }
        phone.onRemoteVideo = { remote = $0 }
        host.onState = { if $0 == "connected" { connected = true } }
        host.offer()
        let deadline = Date().addingTimeInterval(10)
        while (remote == nil || answer.isEmpty || !connected) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let track = try XCTUnwrap(remote)
        XCTAssertTrue(host.repairCodecNegotiationRequested)
        XCTAssertTrue(offer.lowercased().contains("flexfec-03/90000"))
        XCTAssertTrue(phone.repairCodecNegotiationRequested, "Receiver public preferences should include repair")
        XCTAssertTrue(answer.lowercased().contains("flexfec-03/90000"), answer.components(separatedBy: .newlines).filter { $0.hasPrefix("a=rtpmap:") }.joined(separator: " | "))
        XCTAssertTrue(offer.contains("a=ssrc-group:FEC-FR"), "A codec name alone does not prove an assigned repair stream")
        let sink = PacketRepairVideoSink(); track.add(sink); defer { track.remove(sink) }
        let pixels = try (0..<16).map { try frame($0) }
        for index in 0..<150 {
            host.pushFrame(pixels[index % 16], timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9), displayMs: MachClock.nowMs())
            try await Task.sleep(for: .milliseconds(20))
            if sink.count >= 5 { break }
        }
        XCTAssertGreaterThanOrEqual(sink.count, 5, "Negotiated repair path must still deliver genuine decoded RTP")
        host.routeOverrideForTesting = "Direct"; host.offer()
        let removed = Date().addingTimeInterval(5)
        while offer.lowercased().contains("flexfec-03/90000") && Date() < removed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(host.repairCodecNegotiationRequested)
        XCTAssertFalse(offer.lowercased().contains("flexfec-03/90000"))
        // This is not a loss-recovery, real TURN, equal-total-rate or DSCP wire acceptance test.
    }
    private func frame(_ index: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<128 { for x in 0..<256 {
            let at = y * stride + x * 4, value: UInt8 = ((x + index * 9) / 8 + y / 8) % 2 == 0 ? 224 : 16
            base[at] = value; base[at + 1] = value; base[at + 2] = value; base[at + 3] = 255
        } }
        return buffer
    }
}
private final class PacketRepairVideoSink: NSObject, RTCVideoRenderer {
    private let lock = NSLock(); private var frames = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { guard frame != nil else { return }; lock.lock(); frames += 1; lock.unlock() }
}
