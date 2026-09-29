import AppIntents
import Foundation

// Siri, Spotlight, Shortcuts and the Action button.
//
// Safety baseline (SYSTEM-INTEGRATIONS.md section 3.3):
// - Everything that reveals Mac state or opens control requires the phone to be unlocked.
//   Only "End session" runs from a locked phone, because it only moves toward safety.
// - No intent types, clicks, launches apps or runs commands on the Mac. The phone is not trusted
//   by the Mac, and Siri picks the intent and its arguments.
// - Replies are plain: they omit the app name and any humor, and stand alone when spoken.

/// A paired Mac as Shortcuts, Siri and Spotlight name it.
struct MacEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Mac") }
    static var defaultQuery: MacEntityQuery { MacEntityQuery() }

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Paired with this iPhone",
                              image: .init(systemName: "laptopcomputer"))
    }

    init(_ mac: PairedMac) {
        id = mac.id
        name = mac.name
    }
}

struct MacEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MacEntity] {
        PairedMacs.all().filter { identifiers.contains($0.id) }.map(MacEntity.init)
    }

    func suggestedEntities() async throws -> [MacEntity] {
        PairedMacs.all().map(MacEntity.init)
    }
}

enum FarsideIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noPairedMac
    case unknownMac

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPairedMac: "No Mac is paired with Farside yet. Open Farside to pair one."
        case .unknownMac: "That Mac is no longer paired with Farside."
        }
    }
}

/// Picks the Mac an intent means: the one it was given, the only one paired, or, with several and no
/// choice, whichever the person names when asked.
func resolvePairedMac(_ chosen: MacEntity?, disambiguate: ([MacEntity]) async throws -> MacEntity) async throws -> PairedMac {
    let macs = PairedMacs.all()
    guard !macs.isEmpty else { throw FarsideIntentError.noPairedMac }
    if let chosen {
        guard let mac = macs.first(where: { $0.id == chosen.id }) else { throw FarsideIntentError.unknownMac }
        return mac
    }
    if macs.count == 1 { return macs[0] }
    let picked = try await disambiguate(macs.map(MacEntity.init))
    guard let mac = macs.first(where: { $0.id == picked.id }) else { throw FarsideIntentError.unknownMac }
    return mac
}

/// Opens Farside and starts connecting. The person then sees and steers their Mac, so it needs an
/// unlocked phone and the app in front.
struct ConnectToMacIntent: AppIntent {
    static var title: LocalizedStringResource { "Connect to Mac" }
    static var description: IntentDescription? {
        IntentDescription("Opens Farside and connects to your paired Mac.")
    }
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mac", description: "Which Mac to connect to. Farside asks only if you have more than one.",
               requestDisambiguationDialog: "Which Mac?")
    var mac: MacEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$mac)")
    }

    init() {}

    init(mac: MacEntity?) {
        self.mac = mac
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await resolvePairedMac(mac) { options in
            try await $mac.requestDisambiguation(among: options, dialog: "Which Mac?")
        }
        SystemRequestInbox.shared.post(.connect(macID: target.id))
        return .result(dialog: "Connecting to \(target.name).")
    }
}

/// Reports whether the Mac's Farside is answering, without opening a session or the app.
struct MacStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Is my Mac awake?" }
    static var description: IntentDescription? {
        IntentDescription("Checks whether your Mac's Farside is answering, without connecting.")
    }
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mac", description: "Which Mac to check. Farside asks only if you have more than one.",
               requestDisambiguationDialog: "Which Mac?")
    var mac: MacEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check whether \(\.$mac) is awake")
    }

    init() {}

    init(mac: MacEntity?) {
        self.mac = mac
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let target = try await resolvePairedMac(mac) { options in
            try await $mac.requestDisambiguation(among: options, dialog: "Which Mac?")
        }
        let report = await MacStatusService.shared.report(for: target)
        return .result(value: report.state.rawValue, dialog: "\(report.spoken)")
    }
}

/// Every phrase carries the app name, as Apple requires, and names no other product. Connect works
/// from Spotlight, Shortcuts and the Action button without any phrase at all.
struct FarsideShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .tangerine }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToMacIntent(),
            phrases: [
                "Connect to my Mac with \(.applicationName)",
                "Open my Mac in \(.applicationName)",
                "\(.applicationName), reach my Mac",
                "Connect to \(\.$mac) with \(.applicationName)"
            ],
            shortTitle: "Connect to Mac",
            systemImageName: "laptopcomputer"
        )
        AppShortcut(
            intent: EndSessionIntent(),
            phrases: [
                "End my \(.applicationName) session",
                "Disconnect \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "End session",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: MacStatusIntent(),
            phrases: [
                "Is my Mac awake in \(.applicationName)",
                "Check my Mac with \(.applicationName)",
                "\(.applicationName), is my Mac awake"
            ],
            shortTitle: "Is my Mac awake?",
            systemImageName: "moon.zzz"
        )
    }
}
