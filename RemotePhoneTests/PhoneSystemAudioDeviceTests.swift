import XCTest
import AVFoundation
import WebRTC
@testable import PocketDeskRemote

private final class InlineAudioDeviceDelegate: NSObject, RTCAudioDeviceDelegate {
    private(set) var outputInterruptions = 0
    private(set) var outputParameterChanges = 0
    private(set) var isOnOwnerThread = false
    var deferred = false
    var pending: [() -> Void] = []
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {
        XCTAssertTrue(isOnOwnerThread)
        outputParameterChanges += 1
    }
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() { outputInterruptions += 1 }
    func dispatchAsync(_ block: @escaping () -> Void) {
        if deferred { pending.append(block) } else { dispatchSync(block) }
    }
    func dispatchSync(_ block: @escaping () -> Void) {
        isOnOwnerThread = true; defer { isOnOwnerThread = false }; block()
    }
    func drain() {
        let work = pending; pending.removeAll(); work.forEach { dispatchSync($0) }
    }
}

private final class RouteProbe: @unchecked Sendable { var builtIn = false }

final class PhoneSystemAudioDeviceTests: XCTestCase {
    func testOutputTimingIsCachedOnOwnerDispatchAndRefreshesOnRouteChange() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "PocketDeskAVSyncGroup")
        let delegate = InlineAudioDeviceDelegate(); delegate.deferred = true
        var reads = 0, latency = 0.15, duration = 0.02
        let device = PhoneSystemAudioDevice(defaults: defaults, outputTiming: {
            XCTAssertTrue(delegate.isOnOwnerThread)
            reads += 1; return (latency, duration)
        })
        XCTAssertTrue(device.initialize(with: delegate))
        XCTAssertEqual(reads, 0)
        delegate.drain()
        XCTAssertEqual(device.outputLatency, 0.16, "the extra buffer time folds into latency; the buffer size never changes")
        XCTAssertEqual(device.outputIOBufferDuration, 0.01)
        for _ in 0..<50 { _ = device.outputLatency; _ = device.outputIOBufferDuration }
        XCTAssertEqual(reads, 1, "ADM getters never query AVAudioSession")
        XCTAssertEqual(delegate.outputParameterChanges, 1)
        latency = 0.23; duration = 0.03
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        XCTAssertEqual(device.outputLatency, 0.16)
        delegate.drain()
        XCTAssertEqual(device.outputLatency, 0.25)
        XCTAssertEqual(device.outputIOBufferDuration, 0.01)
        XCTAssertEqual(delegate.outputParameterChanges, 2)
        XCTAssertFalse(device.startRecording())
        XCTAssertTrue(device.terminateDevice())
    }

    func testAbsentAndDisabledTimingSwitchKeepLegacyConstantsAndAreSnapshots() {
        for flag in [nil, false] as [Bool?] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            if let flag { defaults.set(flag, forKey: "PocketDeskAVSyncGroup") }
            let device = PhoneSystemAudioDevice(defaults: defaults, outputTiming: {
                XCTFail("Disabled timing must not read the platform session"); return (0.2, 0.02)
            })
            defaults.set(true, forKey: "PocketDeskAVSyncGroup")
            let delegate = InlineAudioDeviceDelegate()
            XCTAssertTrue(device.initialize(with: delegate))
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
            XCTAssertEqual(device.outputLatency, 0)
            XCTAssertEqual(device.outputIOBufferDuration, 0.01)
            XCTAssertEqual(delegate.outputParameterChanges, 0)
            XCTAssertTrue(device.terminateDevice())
        }
    }

    func testRemovedRouteRefreshesTimingWithoutRestartAndLateRefreshCannotReviveTerminatedDevice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "PocketDeskAVSyncGroup")
        let delegate = InlineAudioDeviceDelegate(); delegate.deferred = true
        var reads = 0
        let device = PhoneSystemAudioDevice(defaults: defaults, outputTiming: { reads += 1; return (0.1, 0.02) })
        XCTAssertTrue(device.initialize(with: delegate)); delegate.drain()
        defaults.set(false, forKey: "PocketDeskAVSyncGroup")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        delegate.drain()
        XCTAssertEqual(reads, 2, "Enabled state is captured when the device is created")
        XCTAssertFalse(device.isRenderingForTesting)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertTrue(device.terminateDevice()); delegate.drain()
        XCTAssertEqual(reads, 2, "Queued callbacks after termination cannot read or republish timing")
        XCTAssertEqual(device.outputLatency, 0)
        XCTAssertEqual(device.outputIOBufferDuration, 0.01)
    }

    func testInvalidOutputTimingFallsBackToFiniteLegacyValues() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "PocketDeskAVSyncGroup")
        let device = PhoneSystemAudioDevice(defaults: defaults, outputTiming: { (.nan, -.infinity) })
        XCTAssertTrue(device.initialize(with: InlineAudioDeviceDelegate()))
        XCTAssertEqual(device.outputLatency, 0)
        XCTAssertEqual(device.outputIOBufferDuration, 0.01)
        XCTAssertTrue(device.terminateDevice())
    }

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

    private func playingDevice(route: RouteProbe = RouteProbe()) throws -> (PhoneSystemAudioDevice, InlineAudioDeviceDelegate) {
        let device = PhoneSystemAudioDevice(), delegate = InlineAudioDeviceDelegate()
        device.outputIsBuiltIn = { route.builtIn }
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

    func testPulledHeadphonesNeverRestartOnTheSpeakerBeforeTheMuteLands() throws {
        let route = RouteProbe()
        let (device, _) = try playingDevice(route: route)
        defer { _ = device.terminateDevice() }
        route.builtIn = true
        let stopped = device.stopEngineForTesting()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: stopped)
        XCTAssertFalse(device.isRenderingForTesting, "Headphones → speaker waits for PhoneMediaSession's mute")
        route.builtIn = false
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: stopped)
        XCTAssertTrue(device.isRenderingForTesting, "Headphones → other headphones resumes")
    }

    func testHeadphonesAddedToARunningSpeakerEngineAreRememberedForTheirRemoval() throws {
        let route = RouteProbe(); route.builtIn = true
        let (device, _) = try playingDevice(route: route)
        defer { _ = device.terminateDevice() }
        route.builtIn = false
        let added = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: added)
        route.builtIn = true
        let stopped = device.stopEngineForTesting()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: stopped)
        XCTAssertFalse(device.isRenderingForTesting, "Pulling AirPods that joined mid-playback never restarts on the speaker")
    }

    func testSpeakerPlaybackResumesOnTheSpeaker() throws {
        let route = RouteProbe(); route.builtIn = true
        let (device, _) = try playingDevice(route: route)
        defer { _ = device.terminateDevice() }
        let stopped = device.stopEngineForTesting()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: stopped)
        XCTAssertTrue(device.isRenderingForTesting)
    }
}
