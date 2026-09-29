import Foundation

/// The smallest HTTP/1.1 a local hook needs, parsed strictly. It exists so the loopback bridge accepts
/// exactly one shape of request and refuses everything else before any of it reaches Farside's logic:
/// no chunked bodies, no repeated headers, no pipelining, no query strings.
enum AgentBridgeHTTP {
    static let maxHeadBytes = 8 * 1024
    static let maxBodyBytes = 4 * 1024
    static let maxPathBytes = 256

    enum Status: Int, Equatable {
        case ok = 200, accepted = 202
        case badRequest = 400, unauthorized = 401, forbidden = 403, notFound = 404, methodNotAllowed = 405
        case requestTimeout = 408, payloadTooLarge = 413, unsupportedMediaType = 415, tooManyRequests = 429
        case serviceUnavailable = 503

        var reason: String {
            switch self {
            case .ok: "OK"
            case .accepted: "Accepted"
            case .badRequest: "Bad Request"
            case .unauthorized: "Unauthorized"
            case .forbidden: "Forbidden"
            case .notFound: "Not Found"
            case .methodNotAllowed: "Method Not Allowed"
            case .requestTimeout: "Request Timeout"
            case .payloadTooLarge: "Payload Too Large"
            case .unsupportedMediaType: "Unsupported Media Type"
            case .tooManyRequests: "Too Many Requests"
            case .serviceUnavailable: "Service Unavailable"
            }
        }
    }

    struct Request: Equatable {
        var method: String
        var path: String
        /// Lowercased names. A repeated header is refused, never merged.
        var headers: [String: String]
        var body: Data
    }

    enum Parse: Equatable {
        case needMore
        case request(Request)
        case reject(Status)
    }

    static func parse(_ data: Data) -> Parse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: terminator) else {
            return data.count > maxHeadBytes ? .reject(.badRequest) : .needMore
        }
        guard end.lowerBound <= maxHeadBytes else { return .reject(.badRequest) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .reject(.badRequest) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              requestLine[1].hasPrefix("/"), requestLine[1].utf8.count <= maxPathBytes,
              !requestLine[1].contains("?"), !requestLine[1].contains("#"),
              requestLine[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return .reject(.badRequest) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .reject(.badRequest) }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }), headers[name] == nil else { return .reject(.badRequest) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .reject(.badRequest) }

        var length = 0
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return .reject(.badRequest) }
            guard parsed <= maxBodyBytes else { return .reject(.payloadTooLarge) }
            length = parsed
        }
        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        if available < length { return .needMore }
        if available > length { return .reject(.badRequest) }
        return .request(Request(method: requestLine[0], path: requestLine[1], headers: headers,
                                body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }

    static func response(_ status: Status, json: String = "{}") -> Data {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status.rawValue) \(status.reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func body(_ key: String, _ value: String) -> String {
        "{\"\(key)\":\"\(value)\"}"
    }
}

/// Bearer-token and origin checks for the bridge. Constant-time on the secret; strict on where a
/// request claims to come from, so a web page cannot reach the bridge through the browser.
enum AgentBridgeGuard {
    static func isAuthorized(_ header: String?, token: String) -> Bool {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        return constantTimeEqual(Array(header.dropFirst(7).utf8), Array(token.utf8))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    /// The Host header must name this listener, which defeats DNS rebinding: a rebound name reaches the
    /// bridge carrying the attacker's hostname.
    static func hostIsLocal(_ host: String?, port: UInt16) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Browsers add Origin and Sec-Fetch-* to cross-site requests; a hook never does.
    static func looksLikeBrowser(_ headers: [String: String]) -> Bool {
        headers["origin"] != nil || headers["sec-fetch-site"] != nil || headers["sec-fetch-mode"] != nil
    }
}
