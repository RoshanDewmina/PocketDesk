import Foundation

struct RelayMessage: Codable {
    var type: String
    var guest: GuestRelayFrame?
    var version: Int?
    var role: String?
    var room: String?
    var token: String?
    var clientTokenHash: String?
    var clientTokenHashes: [String]?
    var payload: String?
    var online: Bool?
    var code: String?
    var servers: [ICEServerConfiguration]?
    var policy: String?
    var features: [String]?
    var renew: RenewalOffer?
    var leaseSeconds: Double?
    var renewAfterSeconds: Double?
    var credentialSeconds: Double?
    /// Phone `register` only: the short-lived Farside Anywhere token from the entitlement service.
    var entitlement: String?
    /// `registered` to a phone that listed `remote.1`: "remote" or "local".
    var access: String?
    /// Server-authenticated route.1 policy, received only on this signaling WSS connection.
    var epoch: String?
    var revision: Int?
    var expiresAt: Int64?
}

struct ServerRoutePolicy: Equatable {
    enum Access: String { case local, remote }
    let room: String
    let epoch: String
    let revision: Int
    let access: Access
    let expiresAt: Date

    static func accept(_ message: RelayMessage, room: String, previous: ServerRoutePolicy?, now: Date = Date()) -> Self? {
        guard message.type == "route", message.version == 1, message.room == room,
              let epoch = message.epoch, epoch.count == 32,
              epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let revision = message.revision, revision > (previous?.revision ?? 0),
              previous == nil || previous?.epoch == epoch,
              let accessText = message.access, let access = Access(rawValue: accessText),
              let milliseconds = message.expiresAt, milliseconds > 0 else { return nil }
        let deadline = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        guard deadline > now, deadline.timeIntervalSince(now) <= 86_400 else { return nil }
        return Self(room: room, epoch: epoch, revision: revision, access: access, expiresAt: deadline)
    }
}

@MainActor
protocol MultiDeviceSignalingTransport: SignalingTransport {
    var clientTokenHashes: [String]? { get set }
}

@MainActor
final class SignalingClient: MultiDeviceSignalingTransport {
    var clientTokenHashes: [String]?
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var pending: [String] = []
    private var generation = UUID()
    private var keepalive: SignalingKeepalive?
    private let keepaliveTiming: SignalingKeepalive.Timing
    private(set) var lastCloseReason: String?

    init(keepalive: SignalingKeepalive.Timing = .standard) {
        keepaliveTiming = keepalive
    }

    func connect(invitation: PairInvitation, hostToken: String?, features: [String] = []) throws {
        try connect(invitation: invitation, hostToken: hostToken, features: features, entitlement: nil)
    }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        close()
        guard PairInvitation.validServer(invitation.server), let url = URL(string: invitation.server) else { throw RemoteError.invalidPairing }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 256 * 1024
        self.socket = socket
        let run = generation
        socket.resume()
        send(RelayMessage(type: "register", version: 1, role: hostToken == nil ? "client" : "host",
            room: invitation.room, token: hostToken ?? invitation.token,
            clientTokenHash: hostToken == nil ? nil : SecureRandom.digest(invitation.token),
            clientTokenHashes: hostToken == nil || !features.contains(SignalingFeature.devices) ? nil : clientTokenHashes,
            features: features.isEmpty ? nil : features, entitlement: hostToken == nil ? entitlement : nil))
        let keepalive = SignalingKeepalive(timing: keepaliveTiming, ping: { [weak socket] handler in
            guard let socket else { handler(URLError(.networkConnectionLost)); return }
            socket.sendPing(pongReceiveHandler: handler)
        }, onFailure: { [weak self] failure in
            guard let self, self.generation == run else { return }
            self.lost(failure.rawValue)
        })
        self.keepalive = keepalive
        keepalive.start()
        reader = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let incoming = try await socket.receive()
                    guard let self, self.generation == run else { return }
                    let bytes: Data
                    switch incoming {
                    case .data(let data): bytes = data
                    case .string(let value): bytes = Data(value.utf8)
                    @unknown default: throw RemoteError.invalidMessage
                    }
                    guard bytes.count <= 256 * 1024 else { throw RemoteError.invalidMessage }
                    self.onMessage?(try JSONDecoder().decode(RelayMessage.self, from: bytes))
                }
            } catch {
                guard let self, self.generation == run else { return }
                self.lost("closed by the service or network")
            }
        }
    }
    /// Guest traffic never consumes the native owner queue reserve or closes its signaling socket.
    @discardableResult
    func sendGuest(_ message: RelayMessage) -> Bool {
        guard message.type == "guest", socket != nil, pending.count < 32, let bytes = try? JSONEncoder().encode(message), bytes.count < 256 * 1024 else { return false }
        send(message); return socket != nil
    }
    func send(_ message: RelayMessage) {
        guard socket != nil, pending.count < 64,
              let bytes = try? JSONEncoder().encode(message), bytes.count < 256 * 1024,
              let text = String(data: bytes, encoding: .utf8) else { lost("send refused"); return }
        pending.append(text)
        guard sender == nil else { return }
        let run = generation
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.generation == run, !self.pending.isEmpty {
                    guard let socket = self.socket else { return }
                    let next = self.pending.removeFirst()
                    try await socket.send(.string(next))
                }
                if self.generation == run { self.sender = nil }
            } catch {
                if self.generation == run { self.lost("send failed") }
            }
        }
    }
    func checkLiveness() { keepalive?.probeNow() }

    private func lost(_ reason: String) {
        lastCloseReason = reason
        close(); onClose?()
    }

    func close() {
        generation = UUID()
        keepalive?.stop(); keepalive = nil
        reader?.cancel(); reader = nil
        sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pending.removeAll()
    }
}
