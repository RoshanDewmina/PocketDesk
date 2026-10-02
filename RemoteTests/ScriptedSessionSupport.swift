import XCTest
import Foundation

final class MemoryPairStore: PairPersistence {
    var data: Data?
    var refuseSave = false
    func save<T: Encodable>(_ value: T) throws {
        if refuseSave { throw RemoteError.keychain(-25308) }
        data = try JSONEncoder().encode(value)
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

/// A clock the test moves by hand. Sleepers resume in deadline order as time is advanced.
final class ManualScheduler: RenewalScheduler, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var nextID = 0
    private var sleepers: [Sleeper] = []
    private var cancelledEarly: Set<Int> = []

    func now() -> TimeInterval { lock.withLock { current } }

    func sleep(seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledEarly.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: current + seconds, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledEarly.insert(id)
                lock.unlock()
            }
        }
    }

    var sleeping: Int { lock.withLock { sleepers.count } }

    /// A task created since the last step has not registered its sleeper yet; let it, so its deadline
    /// is measured from the time it asked for rather than from wherever this call moves the clock.
    @MainActor
    func advance(by seconds: TimeInterval) async {
        await settle()
        let target = now() + seconds
        while true {
            let due: Sleeper? = lock.withLock {
                guard let sleeper = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else {
                    current = target
                    return nil
                }
                sleepers.removeAll { $0.id == sleeper.id }
                current = max(current, sleeper.deadline)
                return sleeper
            }
            guard let sleeper = due else { break }
            sleeper.continuation.resume()
            await settle()
        }
        await settle()
    }

    @MainActor
    func settle() async { for _ in 0..<12 { await Task.yield() } }
}

@MainActor
final class ScriptedSignaling: MultiDeviceSignalingTransport {
    var clientTokenHashes: [String]?
    struct Connect {
        let invitation: PairInvitation
        let hostToken: String?
        let features: [String]
    }
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    var onConnect: ((Connect) -> Void)?
    var respond: ((RelayMessage) -> Void)?
    private(set) var connects: [Connect] = []
    private(set) var sent: [RelayMessage] = []
    private(set) var isOpen = false

    var renewals: [RelayMessage] { sent.filter { $0.type == "renew" } }

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        let record = Connect(invitation: invitation, hostToken: hostToken, features: features)
        connects.append(record)
        isOpen = true
        Task { @MainActor [weak self] in self?.onConnect?(record) }
    }

    func send(_ message: RelayMessage) {
        sent.append(message)
        respond?(message)
    }

    func close() { isOpen = false }
    func deliver(_ message: RelayMessage) { onMessage?(message) }
    private(set) var livenessChecks = 0
    private(set) var lastCloseReason: String?
    func checkLiveness() { livenessChecks += 1 }

    func serverCloses(reason: String? = nil) {
        guard isOpen else { return }
        isOpen = false
        lastCloseReason = reason
        onClose?()
    }
}

/// The service side of renewal, following the rules in Server/src/server.ts: a lease that a renewal
/// extends and that closes the connection when it runs out, and relay credentials refreshed once a
/// third of their life is spent.
@MainActor
final class SimulatedRenewalService {
    private let signaling: ScriptedSignaling
    private let scheduler: ManualScheduler
    private let leaseSeconds: Double
    private let credentialSeconds: Double?
    private var leaseEndsAt: Double = 0
    private var leaseTask: Task<Void, Never>?
    private var lastIssuedAt: Double = 0
    private var role = "host"
    private(set) var issued: [(username: String, expiresAt: Double)] = []
    private(set) var leaseExpiries = 0
    private(set) var renewalsHandled = 0
    var onExpired: (() -> Void)?

    init(signaling: ScriptedSignaling, scheduler: ManualScheduler, leaseSeconds: Double, credentialSeconds: Double?) {
        self.signaling = signaling
        self.scheduler = scheduler
        self.leaseSeconds = leaseSeconds
        self.credentialSeconds = credentialSeconds
    }

    func accept(role: String, features: [String], offersRenewal: Bool) {
        self.role = role
        armLease()
        let servers = issue()
        var offer: RenewalOffer?
        if features.contains(SignalingFeature.renewal), offersRenewal {
            offer = RenewalOffer(version: 1, leaseSeconds: leaseSeconds, renewAfterSeconds: nextRenewAfter(),
                                 credentialSeconds: credentialSeconds)
        }
        signaling.deliver(RelayMessage(type: "registered", role: role, renew: offer))
        signaling.deliver(RelayMessage(type: "ice", servers: servers))
    }

    func handle(_ message: RelayMessage) {
        guard message.type == "renew" else { return }
        renewalsHandled += 1
        guard scheduler.now() < leaseEndsAt else { expire(); return }
        armLease()
        var servers: [ICEServerConfiguration]?
        if let ttl = credentialSeconds, scheduler.now() - lastIssuedAt >= ttl / 3 { servers = issue() }
        signaling.deliver(RelayMessage(type: "renewed", servers: servers, leaseSeconds: leaseSeconds,
                                       renewAfterSeconds: nextRenewAfter(),
                                       credentialSeconds: servers == nil ? nil : credentialSeconds))
    }

    func isCurrent(username: String) -> Bool {
        issued.first { $0.username == username }.map { $0.expiresAt > scheduler.now() } ?? false
    }

    private func armLease() {
        leaseTask?.cancel()
        leaseEndsAt = scheduler.now() + leaseSeconds
        let scheduler = scheduler, lease = leaseSeconds
        leaseTask = Task { [weak self] in
            do { try await scheduler.sleep(seconds: lease) } catch { return }
            self?.expire()
        }
    }

    private func expire() {
        leaseExpiries += 1
        leaseTask?.cancel()
        signaling.serverCloses()
        onExpired?()
    }

    private func issue() -> [ICEServerConfiguration] {
        guard let ttl = credentialSeconds else { return [ICEServerConfiguration(urls: ["stun:stun.example.test:3478"])] }
        let username = "\(role)-\(issued.count + 1)"
        issued.append((username, scheduler.now() + ttl))
        lastIssuedAt = scheduler.now()
        return [ICEServerConfiguration(urls: ["stun:stun.example.test:3478"]),
                ICEServerConfiguration(urls: ["turn:relay.example.test:3478"], username: username, credential: "credential-\(username)")]
    }

    private func nextRenewAfter() -> Double {
        var candidates = [leaseSeconds / 2]
        if let ttl = credentialSeconds { candidates.append(max(0, lastIssuedAt + ttl / 3 - scheduler.now())) }
        return max(0.25, candidates.min() ?? leaseSeconds / 2)
    }
}

@MainActor
final class RenewalRig {
    let scheduler = ManualScheduler()
    let signaling = ScriptedSignaling()
    let service: SimulatedRenewalService
    let coordinator: RemoteCoordinator
    private let offersRenewal: Bool

    init(isHost: Bool, advertisesRenewal: Bool = true, serviceOffersRenewal: Bool = true, serviceResponds: Bool = true,
         leaseSeconds: Double = 1800, credentialSeconds: Double? = 3600) {
        offersRenewal = serviceOffersRenewal
        service = SimulatedRenewalService(signaling: signaling, scheduler: scheduler, leaseSeconds: leaseSeconds,
                                   credentialSeconds: credentialSeconds)
        coordinator = RemoteCoordinator(isHost: isHost, store: MemoryPairStore(), retryLimit: 3,
                                        retryBaseNanoseconds: 10_000_000, registrationStableNanoseconds: 50_000_000,
                                        signaling: signaling, renewalScheduler: scheduler,
                                        advertisesRenewal: advertisesRenewal)
        coordinator.allowLegacyPrivateRoute = true
        signaling.onConnect = { [weak self] connect in
            guard let self else { return }
            self.service.accept(role: connect.hostToken == nil ? "client" : "host", features: connect.features,
                                offersRenewal: self.offersRenewal)
        }
        if serviceResponds {
            signaling.respond = { [weak self] message in Task { @MainActor in self?.service.handle(message) } }
        }
    }

    func startHost() async throws {
        _ = try coordinator.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
        coordinator.start()
        await scheduler.settle()
    }

    func startPhone() async throws {
        let mac = RemoteCoordinator(isHost: true, store: MemoryPairStore())
        mac.allowLegacyPrivateRoute = true
        let invitation = try mac.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
        try coordinator.enroll(invitation.code())
        await scheduler.settle()
    }

    var heldRelayUsername: String? { coordinator.iceServersForTesting.compactMap(\.username).first }
}
