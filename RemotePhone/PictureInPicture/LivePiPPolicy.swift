import Foundation

/// Pausing retires work already dequeued, even if playback resumes before conversion finishes.
struct LivePiPConversionEpoch {
    private(set) var enabled = true
    private(set) var generation: UInt64 = 0
    mutating func setEnabled(_ next: Bool) {
        if enabled != next { generation &+= 1; enabled = next }
    }
    var ticket: UInt64? { enabled ? generation : nil }
    func accepts(_ ticket: UInt64) -> Bool { enabled && generation == ticket }
}

/// PiP grants view-only presentation. It never confers input or background network authority.
struct LivePiPPolicy: Equatable {
    enum State: Equatable { case ineligible, ready, starting, active, paused, stopping }
    private(set) var state: State = .ineligible
    private(set) var admission: VideoPresentationAdmission?

    mutating func update(_ next: VideoPresentationAdmission?, at now: TimeInterval) -> Bool {
        guard let next, next.permits(at: now) else {
            let stop = state == .starting || state == .active || state == .paused
            admission = nil; state = stop ? .stopping : .ineligible; return stop
        }
        if let old = admission, old.identity != next.identity {
            let stop = state == .starting || state == .active || state == .paused
            admission = nil; state = stop ? .stopping : .ineligible; return stop
        }
        guard state != .stopping else { return false }
        admission = next
        if state == .ineligible { state = .ready }
        return false
    }
    mutating func userStart(foreground: Bool, supported: Bool, possible: Bool, at now: TimeInterval) -> Bool {
        guard foreground, supported, possible, state == .ready, admission?.permits(at: now) == true else { return false }
        state = .starting; return true
    }
    mutating func didStart(at now: TimeInterval) -> Bool {
        guard state == .starting, admission?.permits(at: now) == true else {
            state = .stopping; admission = nil; return false
        }
        state = .active; return true
    }
    mutating func setPlaying(_ playing: Bool, at now: TimeInterval) {
        guard admission?.permits(at: now) == true else { admission = nil; state = .stopping; return }
        if state == .active || state == .paused { state = playing ? .active : .paused }
    }
    mutating func stop() { admission = nil; state = .stopping }
    mutating func didStop() { admission = nil; state = .ineligible }
    func mayEnqueue(_ identity: VideoPresentationIdentity, at now: TimeInterval) -> Bool {
        (state == .ready || state == .starting || state == .active) && admission?.identity == identity && admission?.permits(at: now) == true
    }
}
