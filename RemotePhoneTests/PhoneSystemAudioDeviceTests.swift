import XCTest
import AVFoundation
import WebRTC
@testable import PocketDeskRemote

private final class InlineAudioDeviceDelegate: NSObject, RTCAudioDeviceDelegate {
    private(set) var outputInterruptions = 0
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() { outputInterruptions += 1 }
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}

final class PhoneSystemAudioDeviceTests: XCTestCase {
    func testNativeRecordingRequestsAreRefusedAcrossLifecycle() {
        let device = PhoneSystemAudioDevice()
        XCTAssertFalse(device.isRecordingInitialized)
        XCTAssertFalse(device.initializeRecording())
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
        device.setConsent(true)
        XCTAssertFalse(device.initializeRecording())
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
        XCTAssertTrue(device.stopRecording())
        XCTAssertTrue(device.terminateDevice())
        XCTAssertFalse(device.isInitialized)
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
    }

    private func playingDevice() throws -> (PhoneSystemAudioDevice, InlineAudioDeviceDelegate) {
        let device = PhoneSystemAudioDevice(), delegate = InlineAudioDeviceDelegate()
        XCTAssertTrue(device.initialize(with: delegate))
        device.setConsent(true)
        XCTAssertTrue(device.startPlayout())
        try XCTSkipUnless(device.isRenderingForTesting, "This simulator has no audio output to start an engine on")
        return (device, delegate)
    }

    func testEngineStoppedByARouteChangeResumesPlayback() throws {
        let (device, _) = try playingDevice()
        defer { _ = device.terminateDevice() }
        let stopped = device.stopEngineForTesting()
        XCTAssertFalse(device.isRenderingForTesting)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: stopped)
        XCTAssertTrue(device.isRenderingForTesting, "Mac audio resumes on the new route instead of going silent")
    }

    func testNewOutputRestartsOnlyAStoppedEngineAndRemovalStaysWithTheMediaSession() throws {
        let (device, delegate) = try playingDevice()
        defer { _ = device.terminateDevice() }
        let interruptions = delegate.outputInterruptions
        let added = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: added)
        XCTAssertEqual(delegate.outputInterruptions, interruptions, "A running engine is not rebuilt")
        _ = device.stopEngineForTesting()
        let removed = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: removed)
        XCTAssertFalse(device.isRenderingForTesting, "Removing headphones never restarts sound on the speaker")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: added)
        XCTAssertTrue(device.isRenderingForTesting)
        device.setConsent(false)
        _ = device.stopEngineForTesting()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: added)
        XCTAssertFalse(device.isRenderingForTesting, "A muted session stays silent")
    }
}
