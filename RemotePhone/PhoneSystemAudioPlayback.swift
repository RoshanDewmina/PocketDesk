import AVFoundation
import WebRTC

/// Receive-only audio. No input node, recorder, microphone source or track.
@MainActor
final class PhoneSystemAudioPlayback {
    private let session: PhoneMediaSession
    private var owner: UUID?
    var onMustMute: (() -> Void)?
    var onSuspended: (() -> Void)?
    var onResumed: (() -> Bool)?
    var isInterrupted: Bool { session.isInterrupted }
    var isAdmitted: Bool { owner.map(session.contains) == true && !session.isInterrupted }

    init(session: PhoneMediaSession = .shared) { self.session = session }
    func begin() -> Bool {
        if let owner, session.contains(owner) { return !session.isInterrupted }
        let next = UUID()
        guard session.acquire(next, kind: .macAudio, onRetired: { [weak self] in
            guard let self, self.owner == next else { return }
            self.owner = nil
            self.onMustMute?()
        }, onSuspended: { [weak self] in
            guard let self, self.owner == next else { return }
            self.onSuspended?()
        }, onResumed: { [weak self] in
            guard let self, self.owner == next else { return false }
            return self.onResumed?() == true
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
