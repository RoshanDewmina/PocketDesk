import AVFoundation
import WebRTC

/// Receive-only audio. This controller creates no input node, recorder, microphone source or track.
@MainActor
final class PhoneSystemAudioPlayback {
    private var observers: [NSObjectProtocol] = []
    private var active = false
    var onMustMute: (() -> Void)?

    init() {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == AVAudioSession.routeChangeNotification,
                       (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                    self?.onMustMute?()
                }
            })
        }
    }

    func begin() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
            if !active { try session.setActive(true); active = true }
            return true
        } catch { return false }
    }

    func end() {
        guard active else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        active = false
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
