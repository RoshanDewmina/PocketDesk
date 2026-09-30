import Foundation

/// WebSocket liveness for the signaling connection. A socket whose path died silently (a router
/// or NAT dropping idle state, an edge eviction without a close frame) never fails `receive()`;
/// only a ping that goes unanswered reveals it. `URLSessionWebSocketTask.sendPing` has no deadline
/// of its own, and its handler may never run on such a socket, so the deadline lives here.
@MainActor
final class SignalingKeepalive {
    struct Timing: Equatable {
        var interval: Duration
        var timeout: Duration
        var minimumProbeSpacing: Duration

        /// Cloudflare closes WebSockets that carry nothing for about 100 s, and home routers expire
        /// idle flows sooner; 25 s keeps the flow warm and notices a dead one within 35 s.
        static let standard = Timing(interval: .seconds(25), timeout: .seconds(10), minimumProbeSpacing: .seconds(5))
    }

    enum Failure: String, Equatable {
        case timeout = "keepalive timed out"
        case pingFailed = "keepalive ping failed"
    }

    typealias Ping = (@escaping @Sendable ((any Error)?) -> Void) -> Void

    private let timing: Timing
    private let ping: Ping
    private let onFailure: (Failure) -> Void
    private let clock = ContinuousClock()
    private var ticker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var outstanding: UUID?
    private var lastProbe: ContinuousClock.Instant?
    private var finished = false
    private(set) var lastPong: Date?

    init(timing: Timing = .standard, ping: @escaping Ping, onFailure: @escaping (Failure) -> Void) {
        self.timing = timing
        self.ping = ping
        self.onFailure = onFailure
    }

    func start() {
        guard !finished, ticker == nil else { return }
        let interval = timing.interval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.send()
            }
        }
    }

    /// Checks the socket now, for example after a network path change or wake.
    func probeNow() {
        if let lastProbe, clock.now - lastProbe < timing.minimumProbeSpacing { return }
        send()
    }

    func stop() {
        finished = true
        ticker?.cancel(); ticker = nil
        deadline?.cancel(); deadline = nil
        outstanding = nil
    }

    private func send() {
        guard !finished, outstanding == nil else { return }
        let id = UUID()
        outstanding = id
        lastProbe = clock.now
        let timeout = timing.timeout
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        ping { [weak self] error in
            Task { @MainActor in self?.answer(id, error: error) }
        }
    }

    private func answer(_ id: UUID, error: (any Error)?) {
        guard outstanding == id else { return }
        outstanding = nil
        deadline?.cancel(); deadline = nil
        if error != nil { fail(.pingFailed) } else { lastPong = Date() }
    }

    private func expire(_ id: UUID) {
        guard outstanding == id else { return }
        fail(.timeout)
    }

    private func fail(_ failure: Failure) {
        guard !finished else { return }
        stop()
        onFailure(failure)
    }
}
