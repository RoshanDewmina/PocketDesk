import Foundation

/// Capabilities a peer lists in `register`. The service only answers with the matching offer when the
/// peer asked for it, and a peer only sends the matching message after receiving that offer, so old
/// services and old apps keep working message for message.
enum SignalingFeature {
    static let route = "route.1"
    static let devices = "devices.1"
    static let renewal = "renew.1"
    /// Phone: understands `registered.access` and a non-closing `entitlement_required`
    /// (Backend/ENTITLEMENT-CONTRACT.md §4).
    static let remoteAccess = "remote.1"
}

/// What the signaling service offers in `registered` once it agrees to renew this peer's room lease
/// (and, when it runs a relay, its TURN credentials) while the session stays connected.
struct RenewalOffer: Codable, Equatable {
    var version: Int
    var leaseSeconds: Double?
    var renewAfterSeconds: Double
    var credentialSeconds: Double?
}

/// The reply to `renew`. `credentialSeconds` is set only when fresh relay credentials came with it.
struct RenewalOutcome: Equatable {
    var leaseSeconds: Double?
    var renewAfterSeconds: Double
    var credentialSeconds: Double?
    var softFailure: String?
}

/// Time source for renewal, injectable so tests can move hours in microseconds.
protocol RenewalScheduler: Sendable {
    /// Monotonic seconds that keep counting while the device sleeps.
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

struct SystemRenewalScheduler: RenewalScheduler {
    private let origin = ContinuousClock.now

    func now() -> TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock.now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
    }

    func sleep(seconds: TimeInterval) async throws {
        try await ContinuousClock().sleep(for: .seconds(seconds))
    }
}

/// When to send the next `renew`, and what to do when the service is slow or refuses. Pure state:
/// every method takes the time it happened, so the schedule can be tested without waiting.
struct RenewalPlan: Equatable {
    static let minimumInterval: TimeInterval = 0.25
    static let maximumInterval: TimeInterval = 3600
    static let responseTimeout: TimeInterval = 10
    static let maximumBackoff: TimeInterval = 30

    private(set) var nextAttemptAt: TimeInterval
    private(set) var leaseEndsAt: TimeInterval?
    private(set) var credentialsEndAt: TimeInterval?
    private(set) var failures = 0
    private(set) var attemptOutstanding = false

    init(offer: RenewalOffer, now: TimeInterval) {
        nextAttemptAt = now + Self.clamp(offer.renewAfterSeconds)
        leaseEndsAt = Self.deadline(offer.leaseSeconds, from: now)
        credentialsEndAt = Self.deadline(offer.credentialSeconds, from: now)
    }

    func delay(from now: TimeInterval) -> TimeInterval { max(0, nextAttemptAt - now) }
    func isDue(at now: TimeInterval) -> Bool { now >= nextAttemptAt }
    func leaseExpired(at now: TimeInterval) -> Bool { leaseEndsAt.map { now >= $0 } ?? false }
    func credentialsExpired(at now: TimeInterval) -> Bool { credentialsEndAt.map { now >= $0 } ?? false }

    /// A `renew` was just sent. If the reply does not arrive in time the same timer sends it again.
    mutating func attemptStarted(at now: TimeInterval) {
        if attemptOutstanding { failures += 1 }
        attemptOutstanding = true
        nextAttemptAt = now + max(Self.responseTimeout, Self.backoff(failures))
    }

    mutating func renewed(_ outcome: RenewalOutcome, at now: TimeInterval) {
        attemptOutstanding = false
        failures = 0
        if let lease = Self.deadline(outcome.leaseSeconds, from: now) { leaseEndsAt = lease }
        if let credentials = Self.deadline(outcome.credentialSeconds, from: now) { credentialsEndAt = credentials }
        nextAttemptAt = now + Self.clamp(outcome.renewAfterSeconds)
    }

    /// The reply arrived but could not be used.
    mutating func attemptFailed(at now: TimeInterval) {
        attemptOutstanding = false
        failures += 1
        nextAttemptAt = now + Self.backoff(failures)
    }

    private static func deadline(_ seconds: Double?, from now: TimeInterval) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return now + seconds
    }

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds.isFinite ? seconds : maximumInterval, minimumInterval), maximumInterval)
    }

    private static func backoff(_ failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(TimeInterval(1 << min(failures, 5)), maximumBackoff)
    }
}

/// The signaling connection as the coordinator sees it. The real one is `SignalingClient`; tests
/// substitute a scripted service.
@MainActor
protocol SignalingTransport: AnyObject {
    var onMessage: ((RelayMessage) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws
    /// A phone registration may carry a Farside Anywhere entitlement token; transports that predate it ignore it.
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws
    func send(_ message: RelayMessage)
    func close()
    /// Pings the open connection now; an unanswered ping closes it through `onClose`.
    func checkLiveness()
    /// Why the last connection ended, for diagnostics; nil when unknown.
    var lastCloseReason: String? { get }
}

extension SignalingTransport {
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        try connect(invitation: invitation, hostToken: hostToken, features: features)
    }
    func checkLiveness() {}
    var lastCloseReason: String? { nil }
}
