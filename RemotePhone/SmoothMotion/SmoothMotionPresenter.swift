import Foundation

/// Paces interpolated output onto the video view's own 120 Hz draws and guarantees the view never
/// receives an older picture after a newer one. Each source frame `s` owns order `2s`; its
/// midpoint with the frame before owns `2s - 1`. Direct (pass-through) frames and paced frames
/// share one ordering, and delivery happens under this lock so the decode thread and the main
/// thread cannot hand the view frames out of order. `deliver` must stay lightweight.
final class SmoothMotionPresenter<Payload>: @unchecked Sendable {
    struct Entry {
        let payload: Payload
        let order: Int64
        /// Minimum time after the previously shown entry, so N follows N-½ by half a source interval.
        let spacing: TimeInterval
        /// When the source frame reached the phone; nil for a midpoint.
        let arrival: TimeInterval?
    }

    struct Delivery {
        let order: Int64
        /// Added hold for a source frame: from its arrival to its hand-off. Nil for midpoints.
        let addedDelay: TimeInterval?
    }

    static var queueLimit: Int { 2 }

    private let lock = NSLock()
    private let deliver: (Payload) -> Void
    private var queue: [Entry] = []
    private var lastOrder: Int64 = 0
    private var lastShownAt = -TimeInterval.infinity
    private var droppedTotal = 0

    init(deliver: @escaping (Payload) -> Void) {
        self.deliver = deliver
    }

    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return !queue.isEmpty
    }

    /// Entries superseded or queued behind newer output before any draw showed them.
    var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedTotal
    }

    var lastDeliveredOrder: Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastOrder
    }

    /// Pass-through: hands the frame over now unless something newer already went. Anything
    /// queued before it is dropped.
    @discardableResult
    func presentNow(_ payload: Payload, order: Int64, at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        dropQueued(before: order)
        guard order > lastOrder else { return false }
        lastOrder = order
        lastShownAt = now
        deliver(payload)
        return true
    }

    /// Queues paced entries (a midpoint and its source). Queued entries older than the first new
    /// one are superseded: the queue never holds more than one source frame's output.
    func enqueue(_ entries: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        let fresh = entries.filter { $0.order > lastOrder }.sorted { $0.order < $1.order }
        droppedTotal += entries.count - fresh.count
        guard let first = fresh.first else { return }
        dropQueued(before: first.order)
        queue.append(contentsOf: fresh)
        while queue.count > Self.queueLimit {
            queue.removeFirst()
            droppedTotal += 1
        }
    }

    /// Called at the start of each video view draw. Hands over at most one entry: the newest one
    /// that is due, dropping due entries behind it. `tick` is the display frame interval.
    @discardableResult
    func pump(at now: TimeInterval, tick: TimeInterval) -> Delivery? {
        lock.lock(); defer { lock.unlock() }
        var chosen: Int?
        for (index, entry) in queue.enumerated() {
            let reference = chosen.map { _ in now } ?? lastShownAt
            guard now + tick / 2 >= reference + entry.spacing else { break }
            chosen = index
            if entry.spacing > 0 { break }
        }
        guard let index = chosen else { return nil }
        let entry = queue[index]
        droppedTotal += index
        queue.removeFirst(index + 1)
        guard entry.order > lastOrder else { return nil }
        lastOrder = entry.order
        lastShownAt = now
        deliver(entry.payload)
        return Delivery(order: entry.order, addedDelay: entry.arrival.map { max(0, now - $0) })
    }

    /// Hands over whatever is queued at once, newest only: used when interpolation disengages
    /// so a held source frame never waits for a draw that pacing no longer needs.
    @discardableResult
    func flush(at now: TimeInterval) -> Delivery? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = queue.last else { return nil }
        droppedTotal += queue.count - 1
        queue.removeAll()
        guard entry.order > lastOrder else { return nil }
        lastOrder = entry.order
        lastShownAt = now
        deliver(entry.payload)
        return Delivery(order: entry.order, addedDelay: entry.arrival.map { max(0, now - $0) })
    }

    func reset() {
        lock.lock(); queue.removeAll(); lastOrder = 0; lastShownAt = -.infinity; droppedTotal = 0; lock.unlock()
    }

    private func dropQueued(before order: Int64) {
        let before = queue.count
        queue.removeAll { $0.order < order }
        droppedTotal += before - queue.count
    }
}
