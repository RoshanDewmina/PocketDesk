import Foundation

/// Host scroll smoothing (`StreamTuning.scrollSmoothing`). Phone scroll messages normally arrive one per
/// touch frame, about 8 ms apart, and post the moment they land. After a stall on the phone's Wi-Fi leg
/// (≈90 ms in the 7 Oct scroll rounds) a dozen held messages land within a few milliseconds; posted at
/// once they move the page ~200 px in one frame. The pacer keeps every message and its order but spaces
/// releases at least `spacing` apart, twice the phone's 120 Hz cadence, so a burst catches up as a short
/// fast glide. A message that arrives on time posts at once, and none waits longer than `maximumHold`.
struct ScrollPacer<Payload> {
    static var spacing: TimeInterval { 1.0 / 240 }
    static var maximumHold: TimeInterval { 0.06 }

    private(set) var pending: [(payload: Payload, release: TimeInterval)] = []
    private var lastRelease: TimeInterval = -.infinity

    var isEmpty: Bool { pending.isEmpty }

    /// Queues `payload` and returns what may post now, oldest first.
    mutating func offer(_ payload: Payload, at now: TimeInterval) -> [Payload] {
        guard now.isFinite else { return flush(at: lastRelease) + [payload] }
        let scheduled = max(now, (pending.last?.release ?? lastRelease) + Self.spacing)
        pending.append((payload, min(scheduled, now + Self.maximumHold)))
        return release(at: now)
    }

    /// Everything due at `now`, oldest first.
    mutating func release(at now: TimeInterval) -> [Payload] {
        var due: [Payload] = []
        while let first = pending.first, first.release <= now {
            due.append(first.payload)
            lastRelease = first.release
            pending.removeFirst()
        }
        return due
    }

    /// Everything still held, oldest first: another input or phase must not overtake it.
    mutating func flush(at now: TimeInterval) -> [Payload] {
        defer { pending.removeAll() }
        if !pending.isEmpty, now.isFinite { lastRelease = now }
        return pending.map(\.payload)
    }

    mutating func discard() { pending.removeAll() }
}
