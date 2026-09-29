import Combine
import Foundation
import UIKit

/// What the handshake needs from StoreKit. `AnywhereStore` provides it; tests provide a fake.
@MainActor
protocol AnywhereEntitlementSource: AnyObject {
    var entitlement: AnywhereEntitlement { get }
    func signedTransaction() async -> String?
}

extension AnywhereStore: AnywhereEntitlementSource {}

enum RemovalResumeError: LocalizedError {
    case unfinished

    var errorDescription: String? {
        "Finish or cancel Server Data removal before pairing or connecting again."
    }
}

/// The entitlement handshake (Backend/ENTITLEMENT-CONTRACT.md): sends the current signed
/// transaction to the service, keeps the token it returns in the Keychain until it expires, and
/// hands it to signaling for `register`. Every failure degrades to "no token": the same Wi-Fi keeps
/// working and the service decides what else a session may use.
@MainActor
final class AnywhereAccess: ObservableObject {
    enum Verification: Equatable {
        case idle, verifying, verified, notConfigured
        /// The service answered no; `reason` is its word for why ("expired", "revoked", "device_limit", …).
        case refused(reason: String?)
        /// No answer, a 5xx or a rate limit.
        case unreachable
    }

    /// What to do after the service asked for Anywhere.
    enum RequiredOutcome: Equatable { case showPaywall, retry, cannotVerify }

    static let shared = AnywhereAccess(source: AnywhereStore.shared)

    @Published private(set) var verification: Verification = .idle
    private(set) var grant: EntitlementGrant?
    var serviceURL: () -> URL? = { nil }

    /// Identifies only the pairing that was present when unlink began; no screen key is retained.
    struct CleanupPairing: Codable, Equatable {
        let room: String
        let server: String
        let tokenDigest: String

        init(_ invitation: PairInvitation) {
            room = invitation.room
            server = invitation.server
            tokenDigest = SecureRandom.digest(invitation.token)
        }
    }
    struct RemovalState: Codable {
        var pending: ServerDataRemovalRequest?
        var cleanup: CleanupPairing?
    }
    @Published private(set) var removalPending = false
    @Published private(set) var localCleanupPending = false
    private let removalPersistence: (any PairPersistence)?
    private var removalState: RemovalState?
    private var removing = false
    @Published private(set) var removalRecoveryRequired = false
    var cleanupPairing: CleanupPairing? { removalState?.pending == nil ? removalState?.cleanup : nil }
    var removalCompleted: Bool { removalState != nil && removalState?.pending == nil && !removalRecoveryRequired }
    /// Also blocks background reconnection after unlink until a person explicitly starts again.
    var phoneConnectionAllowed: Bool { removalState == nil && !removalRecoveryRequired }

    private let source: AnywhereEntitlementSource
    private let makeClient: (URL) -> EntitlementVerifying
    private let deviceID: () -> String?
    private let now: () -> Date
    private let persistence: (any PairPersistence)?
    private var inFlight: Task<Bool, Never>?
    private var refreshAfterFlight = false
    private var refreshTimer: Task<Void, Never>?
    private var retryNotBefore: Date?
    private var retryOrigin: String?
    private var lastEntitlementReconnect: Date?
    private var grantGeneration = 0
    private var observers: Set<AnyCancellable> = []

    init(source: AnywhereEntitlementSource,
         makeClient: @escaping (URL) -> EntitlementVerifying = { HTTPEntitlementClient(baseURL: $0) },
         deviceID: @escaping () -> String? = { InstallIdentity.current()?.deviceID },
         now: @escaping () -> Date = Date.init,
         persistence: (any PairPersistence)? = PairStore(account: "anywhere.token"),
         removalPersistence: (any PairPersistence)? = PairStore(account: "anywhere.removal")) {
        self.removalPersistence = removalPersistence
        do {
            removalState = try removalPersistence?.read(RemovalState.self)
            removalPending = removalState?.pending != nil
            localCleanupPending = removalState?.pending == nil && removalState?.cleanup != nil
        } catch {
            // An unreadable marker may represent a confirmed unlink. Never relink silently.
            removalState = RemovalState(pending: nil, cleanup: nil)
            removalPending = true
            removalRecoveryRequired = true
        }
        self.source = source
        self.makeClient = makeClient
        self.deviceID = deviceID
        self.now = now
        self.persistence = persistence
        if let saved = try? persistence?.read(EntitlementGrant.self), saved.tokenValid(at: now()) {
            grant = saved
        }
    }

    /// Joins the phone's connection: signaling lists `remote.1` and presents the token in `register`,
    /// the service address follows the configuration or the pairing (`AnywhereService`), and a
    /// non-closing `entitlement_required` triggers one verification and, if it yields a token, one reconnect.
    func attach(_ connection: RemoteCoordinator, store: AnywhereStore) {
        connection.advertisesRemoteAccess = true
        connection.startAllowed = { [weak self] in self?.phoneConnectionAllowed ?? false }
        connection.entitlementToken = { [weak self, weak connection] in
            guard let server = connection?.invitation?.server else { return nil }
            return self?.currentToken(forSignalingServer: server)
        }
        serviceURL = { [weak connection] in
            AnywhereService.baseURL(configured: AnywhereService.configured, pairingServer: connection?.invitation?.server,
                                    allowDerived: AnywhereService.allowsDerived)
        }
        observers.removeAll()
        store.$entitlement.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.entitlementChanged() } }
            .store(in: &observers)
        store.onTransactionUpdate = { [weak self] in Task { await self?.refresh(force: true) } }
        connection.$entitlementRequired.removeDuplicates().filter { $0 }
            .sink { [weak self, weak connection] _ in
                Task { @MainActor in if let connection { await self?.serviceAskedForEntitlement(connection) } }
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &observers)
        if source.entitlement.hasAccess { Task { await refresh() } }
    }

    /// The token signaling may present now, or nil.
    func currentToken(forSignalingServer server: String? = nil) -> String? {
        // Right after launch StoreKit has not answered yet; a saved token may still be presented, and
        // the service, which knows about refunds, stays the judge.
        guard removalState == nil else { return nil }
        let phase = source.entitlement.phase
        guard source.entitlement.hasAccess || phase == .unknown,
              let grant, grant.tokenValid(at: now()),
              let service = serviceURL(), let serviceOrigin = origin(service),
              grant.serviceOrigin == serviceOrigin else { return nil }
        if let server {
            guard let signalingURL = AnywhereService.baseURL(configured: nil, pairingServer: server, allowDerived: true),
                  origin(signalingURL) == serviceOrigin else { return nil }
        }
        return grant.token
    }

    /// Asks the service unless the held token is fresh enough (contract §2). `force` asks anyway,
    /// after a purchase, restore or transaction update. Concurrent callers share one request.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard removalState == nil else { return false }
        guard source.entitlement.hasAccess else {
            if source.entitlement.phase != .unknown { clear() }
            return false
        }
        if !force, let grant, currentToken() != nil, !grant.needsRefresh(at: now()) { return true }
        if let retryNotBefore, retryOrigin == serviceURL().flatMap(origin), retryNotBefore > now() {
            return currentToken() != nil
        }
        if let inFlight {
            // A StoreKit renewal/refund may supersede the transaction an earlier verification
            // captured. Coalesce callers, then make one fresh attempt after that response lands.
            if force { refreshAfterFlight = true }
            return await inFlight.value
        }
        refreshAfterFlight = false
        let task = Task {
            let first = await self.verify()
            guard self.refreshAfterFlight else { return first }
            self.refreshAfterFlight = false
            return await self.verify()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if refreshAfterFlight {
            // An update may arrive during the queued second verification, or after its result
            // but before this owner clears inFlight. Start exactly one new flight for that update.
            refreshAfterFlight = false
            Task { [weak self] in await self?.refresh(force: true) }
        }
        return result
    }

    /// Before a person-started connection: gets a token if none is held, but never holds the
    /// connection back longer than `timeout`. A late answer still lands for the next attempt.
    func prepareForConnection(timeout: TimeInterval = 4) async {
        // Only an explicit new Connect resumes verification after a completed unlink.
        do { try resumeAfterCompletedRemoval() }
        catch { return }
        guard source.entitlement.hasAccess else { return }
        guard currentToken() == nil else {
            if grant?.needsRefresh(at: now()) == true { Task { await refresh() } }
            return
        }
        // Not a task group: it would wait for the slower child. Whichever finishes first resumes.
        let verification = Task { await self.refresh() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            Task { @MainActor in _ = await verification.value; finish() }
            Task { @MainActor in try? await Task.sleep(for: .seconds(timeout)); finish() }
        }
    }

    /// The service said this session needs Anywhere. Without a plan, the paywall is the answer (when
    /// the local-only attempt fails). With one, the token was missing, stale or refused, so verify again.
    func resolveEntitlementRequired() async -> RequiredOutcome {
        guard source.entitlement.hasAccess else { return .showPaywall }
        dropGrant()
        return await refresh(force: true) ? .retry : .cannotVerify
    }

    /// Contract §4: `entitlement_required` is non-closing and the session continues on the same
    /// network. With a plan, verify and, if that yields a token, reconnect once so the service can
    /// add internet routes. At most one such reconnect a minute, so a disagreement never loops.
    func serviceAskedForEntitlement(_ connection: RemoteCoordinator) async {
        guard await resolveEntitlementRequired() == .retry, !connection.connected, connection.isRunning else { return }
        if let last = lastEntitlementReconnect, now().timeIntervalSince(last) < 60 { return }
        lastEntitlementReconnect = now()
        connection.start()
    }

    func entitlementChanged() {
        guard removalState == nil else { return }
        if source.entitlement.hasAccess { Task { await refresh() } }
        else if source.entitlement.phase != .unknown { clear() }
    }

    func clear() {
        dropGrant()
        refreshTimer?.cancel(); refreshTimer = nil
        if verification != .idle { verification = .idle }
    }

    /// Keeps removal proof in the Keychain before stopping verification. A lost response is retryable.
    func unlinkDevice(pairing: PairInvitation? = nil,
                      using remover: any ServerDataRemoving = HTTPServerDataRemover()) async throws {
        guard !removing else { throw ServerDataRemovalError.unavailable }
        try recoverRemovalState()
        // A 204 already arrived. Repeating the server request cannot repair local Keychain cleanup.
        if removalCompleted { return }
        let request: ServerDataRemovalRequest
        if let pending = removalState?.pending { request = pending }
        else {
            guard let grant, let token = grant.token, let serviceOrigin = grant.serviceOrigin,
                  let device = deviceID(), let base = serviceURL(), origin(base) == serviceOrigin else {
                throw ServerDataRemovalError.invalidProof
            }
            request = ServerDataRemovalRequest(kind: .device, serviceOrigin: serviceOrigin, identifier: device, proof: token)
            _ = try request.httpRequest()
            let pending = RemovalState(pending: request, cleanup: pairing.map(CleanupPairing.init))
            try removalPersistence?.save(pending)
            removalState = pending
            removalPending = true
        }
        grantGeneration &+= 1
        inFlight?.cancel(); refreshTimer?.cancel(); refreshAfterFlight = false
        removing = true
        defer { removing = false }
        try await remover.remove(request)
        // Persist suppression before clearing the grant: a restart must not re-link through listeners.
        let completed = RemovalState(pending: nil, cleanup: removalState?.cleanup)
        try removalPersistence?.save(completed)
        removalState = completed
        removalPending = false
        localCleanupPending = completed.cleanup != nil
        clear()
    }

    /// Retry after a locked Keychain read; keep connection and verification closed until it succeeds.
    func recoverRemovalState() throws {
        guard removalRecoveryRequired else { return }
        let recovered = try removalPersistence?.read(RemovalState.self)
        removalState = recovered
        removalPending = recovered?.pending != nil
        localCleanupPending = recovered?.pending == nil && recovered?.cleanup != nil
        removalRecoveryRequired = false
    }

    /// A person may explicitly re-pair or connect after the server and local cleanup both finished.
    /// Background reconnect never calls this, and an unreadable or unfinished marker stays closed.
    func resumeAfterCompletedRemoval() throws {
        try recoverRemovalState()
        guard !removing, !removalPending, !localCleanupPending else { throw RemovalResumeError.unfinished }
        guard removalState != nil else { return }
        try removalPersistence?.delete()
        objectWillChange.send()
        removalState = nil
    }

    /// Call only after the coordinator has removed, or safely superseded, the original pairing.
    func acknowledgeLocalCleanup(_ pairing: CleanupPairing) throws {
        guard !removalRecoveryRequired, removalState?.pending == nil,
              removalState?.cleanup == pairing else { throw ServerDataRemovalError.invalidProof }
        let completed = RemovalState(pending: nil, cleanup: nil)
        try removalPersistence?.save(completed)
        removalState = completed
        localCleanupPending = false
    }

    func cancelRemoval() throws {
        guard !removing else { return }
        try recoverRemovalState()
        guard removalState?.pending != nil else { throw ServerDataRemovalError.invalidProof }
        try removalPersistence?.delete()
        removalState = nil
        removalPending = false
        localCleanupPending = false
        removalRecoveryRequired = false
    }

    private func dropGrant() {
        grantGeneration &+= 1
        grant = nil
        try? persistence?.delete()
    }

    private func verify() async -> Bool {
        guard let base = serviceURL(), let serviceOrigin = origin(base) else {
            verification = .notConfigured; return false
        }
        let generation = grantGeneration
        guard let device = deviceID() else { return false }
        guard let signed = await source.signedTransaction() else { return false }
        let currentSignedBeforePost = await source.signedTransaction()
        // StoreKit may suspend while retrieving its JWS. Do not even POST an old transaction if
        // the user removed the plan or the pairing/service changed during that suspension.
        guard contextIsCurrent(generation: generation, origin: serviceOrigin, device: device),
              currentSignedBeforePost == signed else { return false }
        verification = .verifying
        do {
            let answer = try await makeClient(base).verify(EntitlementVerifyRequest(signedTransaction: signed, deviceID: device))
            let currentSigned = await source.signedTransaction()
            guard contextIsCurrent(generation: generation, origin: serviceOrigin, device: device),
                  currentSigned == signed else { return false }
            retryNotBefore = nil
            retryOrigin = nil
            guard answer.entitled, answer.tokenValid(at: now()) else {
                dropGrant()
                verification = .refused(reason: answer.entitled ? nil : answer.reason)
                return false
            }
            var bound = answer
            bound.serviceOrigin = serviceOrigin
            grant = bound
            try? persistence?.save(bound)
            verification = .verified
            scheduleRefresh(bound)
            return true
        } catch EntitlementServiceError.rejected(_, let reason) {
            let currentSigned = await source.signedTransaction()
            guard contextIsCurrent(generation: generation, origin: serviceOrigin, device: device),
                  currentSigned == signed else { return false }
            dropGrant()
            verification = .refused(reason: reason)
            return false
        } catch EntitlementServiceError.rateLimited(let wait) {
            let currentSigned = await source.signedTransaction()
            guard contextIsCurrent(generation: generation, origin: serviceOrigin, device: device),
                  currentSigned == signed else { return false }
            retryNotBefore = now().addingTimeInterval(min(max(wait ?? 60, 1), 3600))
            retryOrigin = serviceOrigin
            verification = .unreachable
            return currentToken() != nil
        } catch {
            let currentSigned = await source.signedTransaction()
            guard contextIsCurrent(generation: generation, origin: serviceOrigin, device: device),
                  currentSigned == signed else { return false }
            // An outage keeps a still-valid token: it should not end a plan that was just confirmed.
            verification = .unreachable
            return currentToken() != nil
        }
    }

    private func contextIsCurrent(generation: Int, origin serviceOrigin: String, device: String) -> Bool {
        removalState == nil && generation == grantGeneration && source.entitlement.hasAccess &&
            serviceURL().flatMap(origin) == serviceOrigin && deviceID() == device
    }

    private func scheduleRefresh(_ grant: EntitlementGrant) {
        refreshTimer?.cancel()
        guard let date = grant.refreshDate(now: now()) else { return }
        let wait = max(1, date.timeIntervalSince(now()))
        refreshTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    private func origin(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              scheme == "https" || scheme == "http" else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }
}
