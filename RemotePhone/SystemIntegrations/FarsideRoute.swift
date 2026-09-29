import Foundation

/// Where a link or a notification tap goes. Routes are navigation only: no link, notification or
/// intent grants any authority. The phone must already be paired to the Mac a request names, and
/// nothing connects until the person chooses to.
enum FarsideRoute: Equatable {
    /// Bring the person to their Mac's Connect screen.
    case openMac
    /// The Live Activity's tap target: back to the session, which the app resumes by itself.
    case resumeSession
    /// A help request from an agent: the "needs you" alert, its sheet and Snooze reminders.
    case agentAlert(id: String)

    static let scheme = "farside"

    /// Hosts whose `/open/...` universal links Farside accepts. The public domain is not chosen yet;
    /// this must change together with the Associated Domains entitlement and the site's
    /// apple-app-site-association file.
    static var associatedHosts: Set<String> = ["farside.example"]

    /// Help request ids are `h_` plus a short token. Anything else is refused before it reaches UI.
    static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }

    static func isHelpRequestID(_ id: String) -> Bool {
        id.hasPrefix("h_") && id.utf8.count > 2 && isValidID(id)
    }

    /// `farside://session`, `farside://open[/<id>]`, `farside://help/<id>`, or
    /// `https://<associated host>/open[/<id>]`.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        var segments: [String]
        switch scheme {
        case Self.scheme:
            guard let host = components.host, !host.isEmpty else { return nil }
            segments = [host.lowercased()] + path
        case "https":
            guard let host = components.host?.lowercased(), Self.associatedHosts.contains(host) else { return nil }
            segments = path
        default:
            return nil
        }
        guard let head = segments.first, segments.count <= 2 else { return nil }
        let argument = segments.count == 2 ? segments[1] : nil
        switch head {
        case "session" where argument == nil:
            self = .resumeSession
        case "help":
            guard let argument, Self.isValidID(argument) else { return nil }
            self = .agentAlert(id: argument)
        case "open":
            if let argument {
                guard Self.isValidID(argument) else { return nil }
                self = Self.isHelpRequestID(argument) ? .agentAlert(id: argument) : .openMac
            } else {
                self = .openMac
            }
        default:
            return nil
        }
    }

    /// The URL a Live Activity or a link should carry for this route.
    var url: URL {
        switch self {
        case .openMac: URL(string: "\(Self.scheme)://open")!
        case .resumeSession: URL(string: "\(Self.scheme)://session")!
        case .agentAlert(let id): URL(string: "\(Self.scheme)://help/\(id)")!
        }
    }
}

/// Requests from outside the view hierarchy (intents, links, notification taps). They queue here so
/// nothing is lost when the system launches the app to run an intent before any screen exists.
enum SystemRequest: Equatable {
    /// Start connecting to the paired Mac. The Mac is named for a future several-Mac picker.
    case connect(macID: String?)
    case route(FarsideRoute)
}

@MainActor
final class SystemRequestInbox: ObservableObject {
    static let shared = SystemRequestInbox()
    @Published private(set) var pending: [SystemRequest] = []

    func post(_ request: SystemRequest) {
        pending.append(request)
    }

    func drain() -> [SystemRequest] {
        let taken = pending
        pending.removeAll()
        return taken
    }
}
