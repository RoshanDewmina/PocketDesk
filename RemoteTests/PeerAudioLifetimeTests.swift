import XCTest
#if os(macOS) && DEBUG && AUDIO_LIFETIME_TESTS
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

#if os(macOS)
final class OpusAudioPolicyTests: XCTestCase {
    private let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 109 111\r\na=sendonly\r\na=rtpmap:109 opus/48000/2\r\na=fmtp:109 minptime=10;useinbandfec=1;stereo=0\r\na=rtpmap:111 telephone-event/8000\r\na=fmtp:111 0-16\r\nm=video 9 UDP/TLS/RTP/SAVPF 109\r\na=rtpmap:109 H264/90000\r\na=fmtp:109 packetization-mode=1\r\n"
    func testStereoSenderAndReceiverParametersStayInTheirAudioPayload() {
        let sender = PeerMedia.opusSDP(sdp, sender: true, enabled: true)
        XCTAssertTrue(sender.contains("sprop-stereo=1"))
        XCTAssertTrue(sender.contains("stereo=0"))
        XCTAssertTrue(sender.contains("useinbandfec=1"))
        XCTAssertTrue(sender.contains("a=fmtp:111 0-16\r\n"))
        XCTAssertTrue(sender.hasSuffix("a=fmtp:109 packetization-mode=1\r\n"))
        let receiver = PeerMedia.opusSDP(sdp.replacingOccurrences(of: "a=sendonly", with: "a=recvonly"), sender: false, enabled: true)
        XCTAssertTrue(receiver.contains("stereo=1"))
        XCTAssertTrue(receiver.contains("maxaveragebitrate=128000"))
        XCTAssertTrue(receiver.contains("a=ptime:20\r\n"))
        XCTAssertFalse(receiver.contains("sprop-stereo=1"))
        XCTAssertEqual(PeerMedia.opusSDP(sender, sender: true, enabled: true), sender)
    }
    func testOpusStereoReadsOnWhenUnsetWhileSyncGroupStaysOptIn() throws {
        let suite = "OpusAudioPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (key, unsetReadsOn) in [("PocketDeskOpusStereo", true), ("PocketDeskAVSyncGroup", false)] {
            XCTAssertEqual(PeerMedia.audioExperimentEnabled(key, unsetReadsOn: unsetReadsOn, defaults: defaults), unsetReadsOn,
                           "\(key) unset: stereo is ON in the .7 test build, sync grouping stays opt-in until glass-to-glass is measured")
            defaults.set(false, forKey: key)
            XCTAssertFalse(PeerMedia.audioExperimentEnabled(key, unsetReadsOn: unsetReadsOn, defaults: defaults))
            defaults.set(true, forKey: key)
            XCTAssertTrue(PeerMedia.audioExperimentEnabled(key, unsetReadsOn: unsetReadsOn, defaults: defaults))
        }
    }
    func testKillSwitchRestoresExactSDPAndEmptyStreamIDs() {
        XCTAssertEqual(PeerMedia.opusSDP(sdp, sender: true, enabled: false), sdp)
        XCTAssertEqual(PeerMedia.audioVideoStreamIDs(enabled: false, sessionID: "fixture"), [])
        XCTAssertEqual(PeerMedia.audioVideoStreamIDs(enabled: true, sessionID: "fixture"), ["fixture"])
        XCTAssertEqual(PeerMedia.audioVideoStreamIDs(enabled: true, zeroPlayoutDelay: true, sessionID: "fixture"), [],
                       "The tuned 0/0 forced playout delay never grants libwebrtc an audio/video sync group")
    }
    func testOnlyOfferedStereo48KOpusIsChangedAndMissingFMTPIsAdded() {
        let input = "v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 112\na=rtpmap:112 opus/48000/2\na=rtpmap:113 opus/48000/2\n"
        let result = PeerMedia.opusSDP(input, sender: false, enabled: true)
        XCTAssertTrue(result.contains("a=fmtp:112 "))
        XCTAssertFalse(result.contains("a=fmtp:113 "))
        let mono = input.replacingOccurrences(of: "opus/48000/2", with: "opus/48000/1")
        XCTAssertEqual(PeerMedia.opusSDP(mono, sender: true, enabled: true), mono)
        let rejected = input.replacingOccurrences(of: "m=audio 9", with: "m=audio 0")
        XCTAssertEqual(PeerMedia.opusSDP(rejected, sender: true, enabled: true), rejected)
    }
}
#endif

#if os(macOS)
/// Each switch state runs in a fresh XCTest process, as the production policy snapshots once.
final class AudioSyncGroupNegotiationTests: XCTestCase {
    func testActualAudioVideoOfferFollowsStartupSwitches() throws {
        let defaults = UserDefaults.standard
        let key = "PocketDeskAVSyncGroup"
        let previous = defaults.object(forKey: key)
        let opusKey = "PocketDeskOpusStereo"
        let previousOpus = defaults.object(forKey: opusKey)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            if let previousOpus { defaults.set(previousOpus, forKey: opusKey) }
            else { defaults.removeObject(forKey: opusKey) }
        }
        // Stereo is ON in the .7 test build when unset (FARSIDE_TEST_OPUS_STEREO=NO runs the legacy
        // process); sync grouping stays opt-in (FARSIDE_TEST_SYNC_GROUP=YES runs the grouped process).
        let environment = ProcessInfo.processInfo.environment
        let stereo = environment["FARSIDE_TEST_OPUS_STEREO"] != "NO"
        let enabled = environment["FARSIDE_TEST_SYNC_GROUP"] == "YES"
        defaults.set(enabled, forKey: key)
        defaults.set(stereo, forKey: opusKey)
        let peer = PeerMedia(isHost: true, servers: [], nativeDesktopCodecs: false)
        defer { peer.close() }
        let offered = expectation(description: "Actual host audio/video offer")
        var identifiers: [String] = []
        peer.onSignal = { signal in
            guard signal.kind == "offer", let sdp = signal.sdp else { return }
            XCTAssertEqual(sdp.contains("sprop-stereo=1"), stereo)
            identifiers = sdp.components(separatedBy: "\r\n").compactMap {
                guard $0.hasPrefix("a=msid:") else { return nil }
                return $0.dropFirst("a=msid:".count).split(separator: " ").first.map(String.init)
            }
            offered.fulfill()
        }
        peer.offer()
        wait(for: [offered], timeout: 5)
        XCTAssertEqual(identifiers.count, 2, "The actual offer must contain audio and video")
        if enabled {
            XCTAssertEqual(Set(identifiers).count, 1)
            XCTAssertNotEqual(identifiers.first, "-")
            XCTAssertFalse(identifiers.first?.isEmpty ?? true)
        } else {
            XCTAssertTrue(identifiers.allSatisfy { $0 == "-" } || Set(identifiers).count == 2,
                          "Legacy transceivers must not acquire a shared nonempty sync group")
        }
    }
}
#endif
