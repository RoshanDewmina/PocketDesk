#if os(macOS) && DEBUG && AUDIO_LIFETIME_TESTS
import XCTest
import Foundation
import Darwin

/// Real PeerMedia/native custom ADM, with synthetic PCM only. No network or hardware capture.
final class PeerAudioLifetimeTests: XCTestCase {
    private let pcm = Data(repeating: 1, count: 1920)

    private func host(local: Bool = false) -> (PeerMedia, FPSystemAudioDevice) {
        let link = local ? ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20") : nil
        let peer = PeerMedia(isHost: true, servers: [], nativeDesktopCodecs: false, localLink: link)
        if local { peer.authorizeAudioPathForLifetimeTesting() }
        let device = peer.audioDeviceForLifetimeTesting!
        XCTAssertTrue(device.isInitialized)
        // Start only the custom ADM; it has no hardware recording path.
        XCTAssertTrue(device.startRecording())
        peer.setSystemAudioEnabled(true)
        return (peer, device)
    }

    private func assertDeliveryRemainsFenced(_ device: FPSystemAudioDevice, frames: UInt) {
        let drained = expectation(description: "Post-fence native delivery observation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(device.deliveredFrames, frames)
    }

    func testCaptureQueueQueuedPCMIsRejectedAfterConsentRevoke() {
        let (peer, device) = host(); defer { peer.close() }
        let epoch = peer.beginSystemAudioCapture()
        let captureQueue = DispatchQueue(label: "audio-test.capture")
        XCTAssertTrue(captureQueue.sync { peer.submitSystemAudio(pcm, epoch: epoch, hostTime: mach_absolute_time()) })
        peer.setSystemAudioEnabled(false)
        let fenced = device.deliveredFrames
        // Work already queued on the capture owner may arrive after the main-thread revoke.
        let late = expectation(description: "Trailing capture callback")
        captureQueue.async {
            XCTAssertFalse(peer.submitSystemAudio(self.pcm, epoch: epoch, hostTime: mach_absolute_time()))
            late.fulfill()
        }
        wait(for: [late], timeout: 2)
        XCTAssertFalse(peer.systemAudioEnabled)
        assertDeliveryRemainsFenced(device, frames: fenced)
    }

    func testCaptureSubmissionAndConsentRaceTerminalPeerClose() {
        let (peer, device) = host()
        let running = expectation(description: "Capture queue started")
        let complete = expectation(description: "Capture queue finished")
        let captureQueue = DispatchQueue(label: "audio-test.race")
        captureQueue.async {
            running.fulfill()
            for _ in 0..<2_000 {
                peer.setSystemAudioEnabled(true)
                let epoch = peer.beginSystemAudioCapture()
                peer.submitSystemAudio(self.pcm, epoch: epoch, hostTime: mach_absolute_time())
                peer.endSystemAudioCapture(epoch)
            }
            complete.fulfill()
        }
        wait(for: [running], timeout: 2)
        peer.close()
        let fenced = device.deliveredFrames
        wait(for: [complete], timeout: 5)
        peer.setSystemAudioEnabled(true)
        XCTAssertFalse(peer.systemAudioEnabled)
        XCTAssertEqual(peer.beginSystemAudioCapture(), 0)
        XCTAssertNil(peer.audioDeviceForLifetimeTesting)
        XCTAssertFalse(peer.submitSystemAudio(pcm, epoch: 1, hostTime: mach_absolute_time()))
        assertDeliveryRemainsFenced(device, frames: fenced)
    }

    func testCallbackRouteCutFencesPCMAndCannotReenableFromMainThread() {
        let (peer, device) = host(local: true); defer { peer.close() }
        let epoch = peer.beginSystemAudioCapture()
        XCTAssertTrue(peer.submitSystemAudio(pcm, epoch: epoch, hostTime: mach_absolute_time()))
        DispatchQueue(label: "audio-test.ice-callback").sync { peer.cutAudioPathForLifetimeTesting() }
        let fenced = device.deliveredFrames
        peer.setSystemAudioEnabled(true)
        peer.setRemoteAudioMuted(false)
        XCTAssertFalse(peer.systemAudioEnabled)
        XCTAssertEqual(peer.beginSystemAudioCapture(), 0)
        XCTAssertFalse(peer.submitSystemAudio(pcm, epoch: epoch, hostTime: mach_absolute_time()))
        assertDeliveryRemainsFenced(device, frames: fenced)
    }

    func testOldPeerTeardownCannotMuteReplacementPeer() {
        let (old, _) = host(), (next, nextDevice) = host()
        defer { next.close() }
        let oldEpoch = old.beginSystemAudioCapture(), nextEpoch = next.beginSystemAudioCapture()
        old.close(); old.setSystemAudioEnabled(false); old.endSystemAudioCapture(oldEpoch)
        XCTAssertFalse(old.submitSystemAudio(pcm, epoch: oldEpoch, hostTime: mach_absolute_time()))
        XCTAssertTrue(next.systemAudioEnabled)
        XCTAssertTrue(nextDevice.consentEnabled)
        XCTAssertTrue(next.submitSystemAudio(pcm, epoch: nextEpoch, hostTime: mach_absolute_time()))
    }
}
#endif
