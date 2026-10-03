#if os(iOS)
import AVFoundation
import WebRTC

/// Output-only public ADM. Recording is refused, and the AVAudioEngine contains no input node.
/// A per-peer device and consent epoch prevent an old callback from playing after mute/End.
final class PhoneSystemAudioDevice: NSObject, RTCAudioDevice {
    var onFailure: (() -> Void)?
    private let lock = NSLock()
    private var audioDelegate: RTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var consent = false
    private var playbackRequested = false
    private var epoch: UInt64 = 0
    private var initialized = false
    private let reportsOutputTiming: Bool
    private let readOutputTiming: () -> (TimeInterval, TimeInterval)
    private var cachedOutputLatency: TimeInterval = 0
    private var cachedOutputBufferDuration: TimeInterval = 0.01
    private var observers: [NSObjectProtocol] = []
    private var startedOnBuiltInOutput = true
    var outputIsBuiltIn: () -> Bool = {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
    }

    /// A new output (AirPods, headphones, CarPlay) can change the hardware format, and AVAudioEngine
    /// then stops itself. Restart on the new route. Removal is left to PhoneMediaSession, which mutes.
    init(defaults: UserDefaults = .standard,
         outputTiming: @escaping () -> (TimeInterval, TimeInterval) = {
             let session = AVAudioSession.sharedInstance()
             return (session.outputLatency, session.ioBufferDuration)
         }) {
        // On in the combined .7 device test; explicit NO keeps the legacy zero-latency constants.
        reportsOutputTiming = defaults.object(forKey: "PocketDeskAVSyncGroup") == nil || defaults.bool(forKey: "PocketDeskAVSyncGroup")
        readOutputTiming = outputTiming
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.restartIfStopped()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let self else { return }
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self.refreshOutputParameters()
                return // Only the media-session owner may retire consent; never restart onto the speaker.
            }
            let builtIn = self.outputIsBuiltIn()
            self.lock.withLock { self.startedOnBuiltInOutput = builtIn } // A running engine follows the new route.
            self.restartIfStopped()
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var deviceInputSampleRate: Double { 48_000 }
    var deviceOutputSampleRate: Double { 48_000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var outputIOBufferDuration: TimeInterval { lock.withLock { cachedOutputBufferDuration } }
    var inputNumberOfChannels: Int { 2 }
    var outputNumberOfChannels: Int { 2 }
    var inputLatency: TimeInterval { 0 }
    var outputLatency: TimeInterval { lock.withLock { cachedOutputLatency } }
    var isInitialized: Bool { lock.withLock { initialized } }
    var isPlayoutInitialized: Bool { true }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }
    var isPlaying: Bool { lock.withLock { playbackRequested } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { audioDelegate = delegate; initialized = true }
        refreshOutputParameters()
        return true
    }
    func terminateDevice() -> Bool {
        setConsent(false)
        lock.withLock {
            audioDelegate = nil; initialized = false; playbackRequested = false
            cachedOutputLatency = 0; cachedOutputBufferDuration = 0.01
        }
        return true
    }
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }
    func initializePlayout() -> Bool { true }
    func startPlayout() -> Bool {
        lock.withLock { playbackRequested = true }
        updateEngine()
        return true
    }
    func stopPlayout() -> Bool {
        lock.withLock { playbackRequested = false; epoch &+= 1 }
        updateEngine()
        return true
    }
    func setConsent(_ enabled: Bool) {
        lock.withLock { consent = enabled; epoch &+= 1 }
        updateEngine()
    }

    private func updateEngine() {
        let delegate = lock.withLock { audioDelegate }
        delegate?.dispatchAsync { [weak self] in self?.applyEngine() }
    }
    private func refreshOutputParameters() {
        guard reportsOutputTiming, let delegate = lock.withLock({ audioDelegate }) else { return }
        delegate.dispatchAsync { [weak self, weak delegate] in
            guard let self, let delegate else { return }
            self.refreshOutputParametersOnOwnerThread(delegate: delegate)
        }
    }
    /// Session access and ADM notifications stay on the owner thread, never in the source render callback.
    private func refreshOutputParametersOnOwnerThread(delegate: RTCAudioDeviceDelegate) {
        guard reportsOutputTiming,
              let currentEpoch = lock.withLock({ initialized && audioDelegate === delegate ? epoch : nil }) else { return }
        let timing = readOutputTiming()
        let latency = timing.0.isFinite && timing.0 >= 0 ? timing.0 : 0
        let duration = timing.1.isFinite && timing.1 > 0 ? timing.1 : 0.01
        let changed = lock.withLock { () -> Bool in
            guard initialized, audioDelegate === delegate, epoch == currentEpoch else { return false }
            guard cachedOutputLatency != latency || cachedOutputBufferDuration != duration else { return false }
            cachedOutputLatency = latency; cachedOutputBufferDuration = duration
            return true
        }
        if changed { delegate.notifyAudioOutputParametersChange() }
    }
    private func restartIfStopped() {
        let delegate = lock.withLock { audioDelegate }
        delegate?.dispatchAsync { [weak self, weak delegate] in
            guard let self, let delegate else { return }
            self.refreshOutputParametersOnOwnerThread(delegate: delegate)
            let (stalled, wasExternal) = self.lock.withLock {
                (self.consent && self.playbackRequested && self.initialized && self.engine?.isRunning != true, !self.startedOnBuiltInOutput)
            }
            // The engine's own configuration change can beat the route change that mutes: never move Mac
            // audio from headphones to the speaker by itself.
            guard stalled, !(wasExternal && self.outputIsBuiltIn()) else { return }
            self.applyEngine()
        }
    }
    #if DEBUG
    var isRenderingForTesting: Bool { lock.withLock { engine?.isRunning == true } }
    func stopEngineForTesting() -> AVAudioEngine? {
        let current = lock.withLock { engine }
        current?.stop()
        return current
    }
    #endif
    /// Runs on the ADM owner thread. Render callbacks use AVAudioEngine's single render thread.
    private func applyEngine() {
        let state = lock.withLock { (consent && playbackRequested && initialized, epoch, audioDelegate, engine) }
        if let previous = state.3 {
            // A stop/route/restart may replace the realtime render thread. Notify before replacement.
            state.2?.notifyAudioOutputInterrupted()
            lock.withLock { engine = nil; source = nil }
            previous.stop()
        }
        guard state.0, let delegate = state.2,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let nativeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true),
              let pcm = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: 4096) else { return }
        // PhoneMediaSession has activated playback before consent is granted.
        refreshOutputParametersOnOwnerThread(delegate: delegate)
        let captureEpoch = state.1
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format) { [weak self, weak delegate] silence, time, count, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard let self, let delegate else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard count <= 4096, self.consent && self.playbackRequested && self.epoch == captureEpoch else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            pcm.frameLength = count
            pcm.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = count * 4
            var flags: AudioUnitRenderActionFlags = []
            let status = delegate.getPlayoutData(&flags, time, 0, count, pcm.mutableAudioBufferList)
            guard status == noErr, let input = pcm.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self), buffers.count == 2 else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            for channel in 0..<2 {
                guard let output = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(count) { output[frame] = Float(input[frame * 2 + channel]) / 32768 }
            }
            silence.pointee = false
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // Publish only if consent is still current; the callback checks the same epoch before PCM.
        guard lock.withLock({ () -> Bool in
            guard consent && playbackRequested && epoch == state.1 else { return false }
            self.engine = engine; self.source = source
            return true
        }) else { return }
        do {
            try engine.start()
            refreshOutputParametersOnOwnerThread(delegate: delegate)
            let builtIn = outputIsBuiltIn()
            lock.withLock { startedOnBuiltInOutput = builtIn }
        } catch {
            lock.withLock { self.engine = nil; self.source = nil; consent = false; epoch &+= 1 }
            engine.stop()
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        }
    }
}
#endif
