import AVFoundation
import WebRTC

/// Receive-only audio. No input node, recorder, microphone source or track.
@MainActor
final class PhoneSystemAudioPlayback {
    private let session: PhoneMediaSession
    private var owner: UUID?
    var onMustMute: (() -> Void)?

    init(session: PhoneMediaSession = .shared) { self.session = session }
    func begin() -> Bool {
        if let owner, session.contains(owner) { return true }
        let next = UUID()
        guard session.acquire(next, kind: .macAudio, onRetired: { [weak self] in
            guard let self, self.owner == next else { return }
            self.owner = nil
            self.onMustMute?()
        }) else { return false }
        owner = next
        return true
    }
    func end() {
        guard let previous = owner else { return }
        owner = nil
        session.release(previous)
    }
    deinit {
        if let owner { let session = session; Task { @MainActor in session.release(owner) } }
    }
}
