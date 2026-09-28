import Foundation

struct RelayMessage: Codable {
    var type: String
    var version: Int?
    var role: String?
    var room: String?
    var token: String?
    var clientTokenHash: String?
    var payload: String?
    var online: Bool?
    var code: String?
    var servers: [ICEServerConfiguration]?
    var policy: String?
}

@MainActor
final class SignalingClient {
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var pending: [String] = []
    private var generation = UUID()

    func connect(invitation: PairInvitation, hostToken: String?) throws {
        close()
        guard PairInvitation.validServer(invitation.server), let url = URL(string: invitation.server) else { throw RemoteError.invalidPairing }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 256 * 1024
        self.socket = socket
        let run = generation
        socket.resume()
        send(RelayMessage(type: "register", version: 1, role: hostToken == nil ? "client" : "host",
            room: invitation.room, token: hostToken ?? invitation.token,
            clientTokenHash: hostToken == nil ? nil : SecureRandom.digest(invitation.token)))
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
                self.close(); self.onClose?()
            }
        }
    }
    func send(_ message: RelayMessage) {
        guard socket != nil, pending.count < 64,
              let bytes = try? JSONEncoder().encode(message), bytes.count < 256 * 1024,
              let text = String(data: bytes, encoding: .utf8) else { close(); onClose?(); return }
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
                if self.generation == run { self.close(); self.onClose?() }
            }
        }
    }
    func close() {
        generation = UUID()
        reader?.cancel(); reader = nil
        sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pending.removeAll()
    }
}
