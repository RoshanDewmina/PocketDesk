import Foundation

/// A removal request carries routing proof only, never the end-to-end screen key.
struct ServerDataRemovalRequest: Codable, Equatable {
    enum Kind: String, Codable { case device, room }
    var kind: Kind
    var serviceOrigin: String
    var identifier: String
    var proof: String

    static func origin(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        return parts.url?.absoluteString
    }

    static func service(for server: String) -> URL? {
        guard PairInvitation.validServer(server), var parts = URLComponents(string: server), parts.scheme == "wss" else { return nil }
        parts.scheme = "https"; parts.path = ""
        return parts.url
    }

    func httpRequest() throws -> URLRequest {
        guard let base = URL(string: serviceOrigin), Self.origin(base) == serviceOrigin,
              SecureRandom.isToken(identifier), !proof.isEmpty, proof.utf8.count <= 512,
              kind != .room || SecureRandom.isToken(proof) else { throw ServerDataRemovalError.invalidProof }
        let path = kind == .device ? "v1/entitlements/forget" : "v1/rooms/forget"
        let body = kind == .device ? ["deviceId": identifier, "entitlementToken": proof] : ["room": identifier, "token": proof]
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum ServerDataRemovalError: Error, LocalizedError, Equatable {
    case invalidProof, unauthorized, blocked, rateLimited, unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidProof: "Removal needs a saved verification from this service. Restore or verify Anywhere first."
        case .unauthorized: "The service could not verify removal. Your saved proof is retained; refresh Anywhere before trying again."
        case .blocked: "The service retained this blocked room. Contact support to resolve the block."
        case .rateLimited: "Too many requests. Wait a minute and retry; your saved proof is retained."
        case .unavailable: "Server removal was not confirmed. Your saved proof is retained so you can retry."
        case .invalidResponse: "The service did not confirm removal. Your saved proof is retained."
        }
    }
}

protocol ServerDataRemoving {
    func remove(_ request: ServerDataRemovalRequest) async throws
}

private final class RemovalNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HTTPServerDataRemover: ServerDataRemoving {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: configuration, delegate: RemovalNoRedirect(), delegateQueue: nil)
    }
    func remove(_ request: ServerDataRemovalRequest) async throws {
        let http = try request.httpRequest()
        let response: URLResponse
        do { (_, response) = try await session.data(for: http) }
        catch { throw ServerDataRemovalError.unavailable }
        guard let response = response as? HTTPURLResponse, response.url == http.url else { throw ServerDataRemovalError.invalidResponse }
        switch response.statusCode {
        case 204: return
        case 401: throw ServerDataRemovalError.unauthorized
        case 403: throw ServerDataRemovalError.blocked
        case 429: throw ServerDataRemovalError.rateLimited
        case 500...599: throw ServerDataRemovalError.unavailable
        default: throw ServerDataRemovalError.invalidResponse
        }
    }
}
