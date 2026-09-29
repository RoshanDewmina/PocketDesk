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

    private let source: AnywhereEntitlementSource
    private let makeClient: (URL) -> EntitlementVerifying
    private let deviceID: () -> String?
    private let now: () -> Date
    private let persistence: (any PairPersistence)?
    private var inFlight: Task<Bool, Never>?
    private var refreshTimer: Task<Void, Never>?
    private var retryNotBefore: Date?
    private var lastEntitlementReconnect: Date?
    private var observers: Set<AnyCancellable> = []

    init(source: AnywhereEntitlementSource,
         makeClient: @escaping (URL) -> EntitlementVerifying = { HTTPEntitlementClient(baseURL: $0) },
         deviceID: @escaping () -> String? = { InstallIdentity.current()?.deviceID },
         now: @escaping () -> Date = Date.init,
         persistence: (any PairPersistence)? = PairStore(account: "anywhere.token")) {
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
        connection.entitlementToken = { [weak self] in self?.currentToken() }
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
    func currentToken() -> String? {
        // Right after launch StoreKit has not answered yet; a saved token may still be presented, and
        // the service, which knows about refunds, stays the judge.
        let phase = source.entitlement.phase
        guard source.entitlement.hasAccess || phase == .unknown, let grant, grant.tokenValid(at: now()) else { return nil }
        return grant.token
    }

    /// Asks the service unless the held token is fresh enough (contract §2). `force` asks anyway,
    /// after a purchase, restore or transaction update. Concurrent callers share one request.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard source.entitlement.hasAccess else {
            if source.entitlement.phase != .unknown { clear() }
            return false
        }
        if !force, let grant, !grant.needsRefresh(at: now()) { return true }
        if let retryNotBefore, retryNotBefore > now() { return currentToken() != nil }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.verify() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// Before a person-started connection: gets a token if none is held, but never holds the
    /// connection back longer than `timeout`. A late answer still lands for the next attempt.
    func prepareForConnection(timeout: TimeInterval = 4) async {
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
        if source.entitlement.hasAccess { Task { await refresh() } }
        else if source.entitlement.phase != .unknown { clear() }
    }

    func clear() {
        dropGrant()
        refreshTimer?.cancel(); refreshTimer = nil
        if verification != .idle { verification = .idle }
    }

    private func dropGrant() {
        grant = nil
        try? persistence?.delete()
    }

    private func verify() async -> Bool {
        guard let base = serviceURL() else { verification = .notConfigured; return false }
        guard let signed = await source.signedTransaction(), let device = deviceID() else { return false }
        verification = .verifying
        do {
            let answer = try await makeClient(base).verify(EntitlementVerifyRequest(signedTransaction: signed, deviceID: device))
            retryNotBefore = nil
            guard answer.entitled, answer.tokenValid(at: now()) else {
                dropGrant()
                verification = .refused(reason: answer.entitled ? nil : answer.reason)
                return false
            }
            grant = answer
            try? persistence?.save(answer)
            verification = .verified
            scheduleRefresh(answer)
            return true
        } catch EntitlementServiceError.rejected(_, let reason) {
            dropGrant()
            verification = .refused(reason: reason)
            return false
        } catch EntitlementServiceError.rateLimited(let wait) {
            retryNotBefore = now().addingTimeInterval(min(max(wait ?? 60, 1), 3600))
            verification = .unreachable
            return currentToken() != nil
        } catch {
            // An outage keeps a still-valid token: it should not end a plan that was just confirmed.
            verification = .unreachable
            return currentToken() != nil
        }
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
}
