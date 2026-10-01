import Foundation
#if canImport(UIKit)
import AVFoundation
#endif

/// One owner of the process-wide platform session. The injected backend never runs in fixtures.
@MainActor
final class PhoneMediaSession {
    enum Kind: Hashable { case macAudio, pictureInPicture, recording }
    enum Configuration: Equatable { case playback, recording }
    struct Backend {
        let configure: (Configuration) throws -> Void
        let activate: () throws -> Void
        let deactivate: () throws -> Void
    }
    private struct Entry {
        let kind: Kind
        let retired: () -> Void
        let suspended: () -> Void
        let resumed: () -> Bool
    }
    private var owners: [UUID: Entry] = [:]
    private var retiring = false
    private var acquiring = false
    private var deactivating = false
    private var generation: UInt64 = 0
    private(set) var isInterrupted = false
    private let backend: Backend
    private var observers: [NSObjectProtocol] = []
    private(set) var lastOperationFailed = false

    #if canImport(UIKit)
    static let shared = PhoneMediaSession(backend: .init(configure: { configuration in
        let session = AVAudioSession.sharedInstance()
        switch configuration {
        case .playback:
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
        case .recording: try session.setCategory(.record, mode: .measurement)
        }
    }, activate: { try AVAudioSession.sharedInstance().setActive(true) },
       deactivate: { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }), observesPlatform: true)
    #endif

    init(backend: Backend, observesPlatform: Bool = false) {
        self.backend = backend
        #if canImport(UIKit)
        if observesPlatform {
            let center = NotificationCenter.default
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                         AVAudioSession.mediaServicesWereResetNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == AVAudioSession.interruptionNotification {
                            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                            if type == AVAudioSession.InterruptionType.began.rawValue { self?.beginInterruption() }
                            else if type == AVAudioSession.InterruptionType.ended.rawValue {
                                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                                self?.endInterruption(shouldResume: AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume))
                            }
                            return
                        }
                        if note.name == AVAudioSession.routeChangeNotification {
                            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                                  reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                            self?.routeChanged()
                            return
                        }
                        self?.retireAll()
                    }
                })
            }
        }
        #endif
    }

    func contains(_ owner: UUID) -> Bool { owners[owner] != nil }
    @discardableResult
    func acquire(_ owner: UUID, kind: Kind, onRetired: @escaping () -> Void,
                 onSuspended: @escaping () -> Void = {}, onResumed: @escaping () -> Bool = { false }) -> Bool {
        guard !retiring, !acquiring, !deactivating, !isInterrupted else { return false }
        if let existing = owners[owner] { return existing.kind == kind }
        guard owners.count < 8,
              kind != .recording || owners.isEmpty,
              !owners.values.contains(where: { $0.kind == .recording }) else { return false }
        if owners.isEmpty {
            acquiring = true
            defer { acquiring = false }
            let current = generation
            do {
                try backend.configure(kind == .recording ? .recording : .playback)
                try backend.activate()
                guard generation == current else {
                    deactivate()
                    lastOperationFailed = true
                    return false
                }
                lastOperationFailed = false
            } catch {
                // No sibling owner exists. Undo any partially activated configuration.
                deactivate()
                lastOperationFailed = true
                return false
            }
        }
        owners[owner] = Entry(kind: kind, retired: onRetired, suspended: onSuspended, resumed: onResumed)
        return true
    }

    @discardableResult
    func release(_ owner: UUID) -> Bool {
        guard owners.removeValue(forKey: owner) != nil else { return false }
        if owners.isEmpty && !retiring && !acquiring { deactivate() }
        return true
    }

    /// Temporary OS suspension retains only the already-admitted playback owners. Recording is terminal.
    func beginInterruption() {
        guard !isInterrupted else { return }
        if acquiring || owners.values.contains(where: { $0.kind == .recording }) { retireAll(); return }
        isInterrupted = true
        let current = generation
        let previous = owners
        for (id, entry) in previous {
            guard isInterrupted, generation == current else { return }
            if owners[id] != nil { entry.suspended() }
        }
    }
    func endInterruption(shouldResume: Bool) {
        guard isInterrupted else { return } // A late ended notification cannot revive retired owners.
        guard shouldResume, !owners.isEmpty, !acquiring, !retiring, !deactivating else { retireAll(); return }
        acquiring = true
        defer { acquiring = false }
        let current = generation
        do { try backend.activate() }
        catch { retireAll(); lastOperationFailed = true; return }
        guard isInterrupted, generation == current else { return }
        isInterrupted = false
        let previous = owners
        for (id, entry) in previous {
            guard generation == current else { return }
            guard owners[id] != nil else { continue }
            let resume = entry.resumed()
            guard generation == current else { return }
            if !resume, owners.removeValue(forKey: id) != nil { entry.retired() }
        }
        if owners.isEmpty { deactivate() }
    }

    /// Irreversible retirement: callbacks stop/mute actual consumers before final deactivation.
    func retireAll() {
        generation &+= 1 // An interruption during first activation also retires that acquisition.
        isInterrupted = false
        guard !retiring, !owners.isEmpty else { return }
        retiring = true
        let previous = Array(owners.values)
        owners.removeAll()
        previous.forEach { $0.retired() }
        deactivate()
        retiring = false
    }
    /// Plugging or unplugging headphones must not end a background PiP (and with it the session).
    /// Mac audio stays retired until the user opts in again; the microphone's input route changed.
    func routeChanged() { retire(kinds: [.macAudio, .recording]) }

    func retire(kinds: Set<Kind>) {
        guard !acquiring else { retireAll(); return } // The pending owner's kind is unknown.
        guard !retiring else { return }
        let matching = owners.filter { kinds.contains($0.value.kind) }
        guard !matching.isEmpty else { return }
        retiring = true
        matching.keys.forEach { owners.removeValue(forKey: $0) }
        matching.values.forEach { $0.retired() }
        retiring = false
        guard owners.isEmpty else { return }
        generation &+= 1
        isInterrupted = false
        deactivate()
    }
    private func deactivate() {
        guard !deactivating else { return }
        deactivating = true
        defer { deactivating = false }
        do { try backend.deactivate(); lastOperationFailed = false }
        catch { lastOperationFailed = true }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
