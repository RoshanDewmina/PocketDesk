import Foundation

/// Asks the connection service whether the paired Mac's Farside is online right now, without starting
/// a session. It registers as the phone, waits for the service's first answer and leaves.
///
/// The service lets a phone register only while the Mac is registered in the same room, so a
/// `registered` reply means the Mac's Farside is running and reachable. The service deliberately
/// answers one code for "the Mac is not there" and "you are not authorized", so a refusal is reported
/// as "not answering", never as "asleep".
///
/// It registers with `probe.1` only. The service checks the phone's credentials, answers and closes the
/// socket without admitting it: the probe never takes or replaces the phone's place, even from an intent
/// process while the app holds a quiet session, and the Mac never hears of it. While any phone is
/// registered the service answers `already_connected`. It deliberately does not list `route.1`: a service
/// that predates `probe.1` then refuses it as `upgrade_required` on public deployments instead of
/// admitting it as a phone that could replace a live session.
@MainActor
final class MacReachabilityProbe {
    static let features = ["probe.1"]

    enum Outcome: Equatable {
        /// The Mac's Farside answered: the Mac is awake and online.
        case answering
        /// The service has no Mac in this room. It may be asleep, off, offline, or the pairing was removed.
        case notAnswering
        /// A phone is already registered in this room, so the probe could not ask.
        case sessionBusy
        /// The service could not be reached or did not answer in time.
        case serviceUnreachable
    }

    private let timeout: TimeInterval
    private let makeTransport: @MainActor () -> any SignalingTransport
    private var transport: (any SignalingTransport)?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: TimeInterval = 6,
         makeTransport: @escaping @MainActor () -> any SignalingTransport = { SignalingClient() }) {
        self.timeout = timeout
        self.makeTransport = makeTransport
    }

    func check(_ invitation: PairInvitation) async -> Outcome {
        guard continuation == nil else { return .sessionBusy }
        let transport = makeTransport()
        self.transport = transport
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            transport.onMessage = { [weak self] message in self?.receive(message) }
            transport.onClose = { [weak self] in self?.finish(.serviceUnreachable) }
            do {
                try transport.connect(invitation: invitation, hostToken: nil, features: Self.features)
            } catch {
                finish(.serviceUnreachable)
                return
            }
            let seconds = timeout
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.serviceUnreachable)
            }
        }
    }

    private func receive(_ message: RelayMessage) {
        switch message.type {
        case "registered":
            finish(.answering)
        case "error":
            switch message.code {
            case "host_unavailable_or_unauthorized": finish(.notAnswering)
            case "already_connected": finish(.sessionBusy)
            default: finish(.serviceUnreachable)
            }
        default:
            break
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        transport?.onMessage = nil
        transport?.onClose = nil
        transport?.close()
        transport = nil
        continuation.resume(returning: outcome)
    }
}
