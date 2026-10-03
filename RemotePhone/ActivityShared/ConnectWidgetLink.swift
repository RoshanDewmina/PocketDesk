import Foundation
import AppIntents

/// Where a tap on the Home Screen Connect widget goes. Compiled into the app and the widget
/// extension; the app routes it through `FarsideRoute.openMac`, which asks before connecting.
enum ConnectWidgetLink {
    static let kind = "FarsideConnect"
    static let url = URL(string: "farside://open")!
}

/// Display data only; the app resolves the destination from its own paired-Mac store.
enum FarsideControlConnect {
    static let kind = "FarsideControlConnect"
    static let defaultsKey = "FarsideControlConnect"
    static let resultText = "Opening Farside."

    static func title(snapshot: MacWidgetSnapshot?) -> String {
        let name = snapshot?.macName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Connect to Mac" : "Connect to \(name)"
    }
}

enum ControlConnectDestination: String, AppEnum {
    case mac
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mac" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.mac: "Mac"] }
}

/// OpenIntent is WidgetKit's app-opening contract. Target membership in both processes lets the
/// system foreground the app; only the app may resolve pairing or enqueue a Connect request.
struct ControlConnectIntent: OpenIntent {
    static var title: LocalizedStringResource { "Connect to Mac" }
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Destination") var target: ControlConnectDestination

    init() { target = .mac }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if !FARSIDE_WIDGET_EXTENSION
        ControlConnectRequest.post()
        #endif
        return .result(dialog: "\(FarsideControlConnect.resultText)")
    }
}
