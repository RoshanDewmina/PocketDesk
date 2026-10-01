import Foundation
#if canImport(UIKit)
import AVFoundation
#endif

/// One owner of the process-wide platform session. The injected backend never runs in fixtures.
@MainActor
final class PhoneMediaSession {
    enum Kind: Equatable { case macAudio, pictureInPicture, recording }
    enum Configuration: Equatable { case playback, recording }
    struct Backend {
        let configure: (Configuration) throws -> Void
        let activate: () throws -> Void
        let deactivate: () throws -> Void
    }
    private struct Entry { let kind: Kind; let retired: () -> Void }
    private var owners: [UUID: Entry] = [:]
    private var retiring = false
    private var acquiring = false
    private var generation: UInt64 = 0
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
                        if note.name == AVAudioSession.interruptionNotification,
                           (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                        if note.name == AVAudioSession.routeChangeNotification,
                           (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                        self?.retireAll()
                    }
                })
            }
        }
        #endif
    }

    func contains(_ owner: UUID) -> Bool { owners[owner] != nil }
    @discardableResult
    func acquire(_ owner: UUID, kind: Kind, onRetired: @escaping () -> Void) -> Bool {
        guard !retiring, !acquiring else { return false }
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
                    lastOperationFailed = true
                    try? backend.deactivate()
                    return false
                }
                lastOperationFailed = false
            } catch {
                lastOperationFailed = true
                // No sibling owner exists. Undo any partially activated configuration.
                try? backend.deactivate()
                return false
            }
        }
        owners[owner] = Entry(kind: kind, retired: onRetired)
        return true
    }

    @discardableResult
    func release(_ owner: UUID) -> Bool {
        guard owners.removeValue(forKey: owner) != nil else { return false }
        if owners.isEmpty && !retiring { deactivate() }
        return true
    }

    /// No automatic restart: callbacks stop/mute their actual consumers before final deactivation.
    func retireAll() {
        generation &+= 1 // An interruption during first activation also retires that acquisition.
        guard !retiring, !owners.isEmpty else { return }
        retiring = true
        let previous = Array(owners.values)
        owners.removeAll()
        previous.forEach { $0.retired() }
        deactivate()
        retiring = false
    }
    private func deactivate() {
        do { try backend.deactivate(); lastOperationFailed = false }
        catch { lastOperationFailed = true }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
