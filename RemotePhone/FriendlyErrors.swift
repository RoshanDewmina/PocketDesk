import SwiftUI

/// A failure told in plain words: what happened, one fix, one button. Built from what the
/// connection or the Mac actually reported; it never guesses a cause it was not told.
struct FriendlyError: Identifiable, Equatable {
    enum Kind: String {
        case napping, unreachable, busy, locked, switchedUser, needsPlan, codeRejected, declined,
             approvalTimedOut, verifyFailed, keychain, relayUnavailable, connectionLost, sessionGlitch,
             serviceNotReady, screenSharingOff, anywhereUnverified, macNotResponding, screenRecordingOff,
             localNetworkOff, screenRecordingApproval, couchNotLocal, couchControlOff
    }

    enum Action: Equatable {
        case retry, pairAgain, seePlans, openSettings, connectWithPicture
        var title: String {
            switch self {
            case .retry: "Try again"
            case .pairAgain: "Pair again"
            case .seePlans: "See Farside Anywhere"
            case .openSettings: "Open Settings"
            case .connectWithPicture: CouchCopy.connectWithPicture
            }
        }
    }

    let kind: Kind
    let headline: String
    var accent: String?
    let message: String
    let fix: String
    var tipTitle: String?
    var tip: String?
    var action: Action = .retry
    /// A quieter second choice under the button.
    var secondary: Action?
    var footnote: String?

    var id: String { kind.rawValue }

    static func == (lhs: FriendlyError, rhs: FriendlyError) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message
    }

    var scene: FarsideArt.Scene {
        switch kind {
        case .napping: FarsideArt.nap
        case .locked, .switchedUser, .verifyFailed, .keychain, .declined, .couchControlOff: FarsideArt.locked
        case .needsPlan, .relayUnavailable, .serviceNotReady, .anywhereUnverified: FarsideArt.anywhere
        case .codeRejected: FarsideArt.staleCode
        case .screenSharingOff, .screenRecordingOff, .screenRecordingApproval: FarsideArt.screenOff
        case .localNetworkOff: FarsideArt.priming(.localNetwork)
        case .unreachable, .busy, .approvalTimedOut, .connectionLost, .sessionGlitch, .macNotResponding, .couchNotLocal: FarsideArt.unreachable
        }
    }

    /// Short status for the Home card once the full screen is dismissed.
    var shortStatus: String {
        switch kind {
        case .napping: "Asleep · wake it to connect"
        case .locked: "Locked · unlock it in person"
        case .switchedUser: "Another user is on it"
        case .needsPlan: "Not on this network"
        case .busy: "Still closing the last session"
        case .declined: "Declined on the Mac"
        case .approvalTimedOut: "Not approved in time"
        case .verifyFailed, .sessionGlitch: "Stopped to stay safe"
        case .keychain: "Pairing locked · unlock this \(DeviceWord.current)"
        case .codeRejected: "Pairing code not accepted"
        case .relayUnavailable, .serviceNotReady: "Anywhere unavailable"
        case .unreachable, .connectionLost: "Couldn’t reach it"
        case .screenSharingOff: "Screen sharing stopped"
        case .screenRecordingOff: "Screen Recording off on Mac"
        case .screenRecordingApproval: "Approve screen recording on Mac"
        case .anywhereUnverified: "Anywhere not confirmed"
        case .macNotResponding: "Found it · not answering"
        case .localNetworkOff: "Local Network off · turn it on in Settings"
        case .couchNotLocal: "Not on your Mac’s network"
        case .couchControlOff: "Control is off on the Mac"
        }
    }

    // MARK: Catalog

    static func napping(since time: String?) -> FriendlyError {
        FriendlyError(kind: .napping, headline: "Your Mac is napping",
                      message: time.map { "It went to sleep at \($0), so it can’t hear your phone." }
                        ?? "It went to sleep, so it can’t hear your phone.",
                      fix: "Tap any key on the Mac or open its lid, then try again.",
                      tipTitle: "Fewer naps",
                      tip: "On the Mac, turn on Wake for network access in Battery settings. One switch, once.",
                      footnote: "Macs can’t hear phones while they sleep. We checked.")
    }

    static func locked(since time: String?) -> FriendlyError {
        FriendlyError(kind: .locked, headline: "Your Mac is locked",
                      message: (time.map { "It was locked at \($0). " } ?? "") + "Farside can’t unlock it for you.",
                      fix: "Unlock it in person, then reconnect.")
    }

    static func switchedUser(since time: String?) -> FriendlyError {
        FriendlyError(kind: .switchedUser, headline: "Someone else is on your Mac",
                      message: time.map { "Another user started using it at \($0)." } ?? "Another user started using it.",
                      fix: "Switch back to your account on the Mac, then reconnect.")
    }

    static func unreachable(_ mac: String) -> FriendlyError {
        FriendlyError(kind: .unreachable, headline: "Your Mac is out of reach", accent: "reach",
                      message: "\(mac) may be asleep, offline, or Farside isn’t running in its menu bar.",
                      fix: "Check that it’s awake and Farside is open, then try again.",
                      tipTitle: "Same Wi-Fi",
                      tip: "Free Farside works when your \(DeviceWord.current) and Mac share a network.")
    }

    /// The service had the Mac's room open but the Mac never answered the handshake: its end of the
    /// service connection went quiet. Where the phone is has nothing to do with it.
    static func macNotResponding(_ mac: String) -> FriendlyError {
        FriendlyError(kind: .macNotResponding, headline: "Your Mac isn’t answering", accent: "answering",
                      message: "Farside found \(mac), but it didn’t respond. Its connection to Farside may have dropped.",
                      fix: "Try again in a minute. If it still doesn’t answer, open Farside on the Mac and check it says Ready.")
    }

    /// Only someone at the Mac can fix this, so no Retry is offered.
    static let screenSharingOff = FriendlyError(kind: .screenSharingOff, headline: "Your Mac stopped sharing",
                                                message: "Its screen stopped reaching Farside. Screen Recording may need renewing, and only someone at the Mac can do that.",
                                                fix: "Open Farside on your Mac and check Screen Recording.")

    /// The Mac answered and said so itself: it has no Screen Recording grant.
    static let screenRecordingOff = FriendlyError(kind: .screenRecordingOff, headline: "Screen Recording is off on your Mac",
                                                  accent: "off",
                                                  message: "Your Mac answered, but Farside there isn’t allowed to record the screen, so it can’t share it.",
                                                  fix: "On your Mac: System Settings → Privacy & Security → Screen Recording → Farside.")

    /// iOS reported Local Network access denied. Only the person can turn it back on, in Settings.
    static let localNetworkOff = FriendlyError(kind: .localNetworkOff, headline: LocalNetworkAccess.deniedTitle,
                                               accent: "off",
                                               message: LocalNetworkAccess.deniedDetail,
                                               fix: LocalNetworkAccess.deniedNextStep,
                                               tipTitle: "Away from home?",
                                               tip: "Farside Anywhere connects without Local Network access.",
                                               action: .openSettings, secondary: .retry)
    /// The Mac answered and said macOS paused its screen recording until someone approves it there.
    /// The Mac shares again by itself once approved, so the steps end with trying again.
    static let screenRecordingApproval = FriendlyError(
        kind: .screenRecordingApproval, headline: "Approve screen recording on your Mac", accent: "Approve",
        message: "Your Mac answered, but macOS paused Farside’s screen recording there until someone at the Mac approves it. Farside can’t approve it for you.",
        fix: screenRecordingApprovalSteps)

    static let screenRecordingApprovalSteps = "At your Mac: 1. If macOS asks whether Farside may keep recording the screen, allow it. "
        + "2. No prompt? Open System Settings → Privacy & Security → Screen & System Audio Recording and switch on Farside. "
        + "3. Come back here and tap Try again. Farside on your Mac picks it up by itself."

    static let busy = FriendlyError(kind: .busy, headline: "Hang on a second",
                                    message: "Farside is still closing your last session.",
                                    fix: "Try again in a few seconds.")

    /// A same-network-only attempt failed, or the service said the connection needs Farside Anywhere,
    /// and this phone has no plan. The Mac may also simply be asleep nearby, so both fixes are named.
    static let needsPlan = FriendlyError(kind: .needsPlan, headline: "Your Mac isn’t on this network", accent: "isn’t",
                                         message: "Free Farside connects when your \(DeviceWord.current) and Mac share a Wi-Fi network, and your Mac didn’t answer on this one.",
                                         fix: "If it’s nearby, check it’s awake and on this Wi-Fi. If it’s elsewhere, Farside Anywhere reaches it from any network.",
                                         tipTitle: "Farside Anywhere",
                                         tip: "Cellular or any Wi-Fi, with no VPN or port forwarding. Cancel anytime in Settings.",
                                         action: .seePlans, secondary: .retry)

    /// The phone has a plan, but the service could not confirm it just now.
    static let anywhereUnverified = FriendlyError(kind: .anywhereUnverified, headline: "Couldn’t confirm Anywhere", accent: "Anywhere",
                                                  message: "Your plan is active on this \(DeviceWord.current), but Farside’s service couldn’t confirm it just now.",
                                                  fix: "Check your connection and try again. On your Mac’s Wi-Fi, Farside works without it.",
                                                  secondary: .seePlans)

    static let codeRejected = FriendlyError(kind: .codeRejected, headline: "That code went stale",
                                            message: "Pairing codes last two minutes, and this one didn’t work.",
                                            fix: "On your Mac, choose Pair a phone for a fresh code, then scan again.",
                                            action: .pairAgain)

    static let declined = FriendlyError(kind: .declined, headline: "Your Mac said no",
                                        message: "Someone chose Decline on the Mac.",
                                        fix: PhoneRecovery.enabled ? "If that was a mistake, try again and choose Allow on your Mac."
                                            : "If that was a mistake, pair again and choose Allow.",
                                        action: PhoneRecovery.enabled ? .retry : .pairAgain)

    static let approvalTimedOut = FriendlyError(kind: .approvalTimedOut, headline: "Nobody said yes",
                                                message: "Your Mac asked, but nobody chose Allow in time.",
                                                fix: "Try again and choose Allow on your Mac.")

    static let verifyFailed = FriendlyError(kind: .verifyFailed, headline: "Could not verify your Mac",
                                            message: "The secure handshake didn’t match, so Farside stopped.",
                                            fix: PhoneRecovery.enabled ? "Try again. If it keeps happening, open Farside on your Mac and check it says Ready."
                                                : "Try again. If it keeps happening, pair again.")

    static let keychain = FriendlyError(kind: .keychain, headline: "Could not save this pairing",
                                        message: "iOS didn’t let Farside store the pairing key.",
                                        fix: "Unlock this \(DeviceWord.current) and try again.")

    static let relayUnavailable = FriendlyError(kind: .relayUnavailable, headline: "Anywhere is unavailable",
                                                message: "Farside couldn’t set up an internet connection to your Mac just now.",
                                                fix: "Check that both devices have internet access, then try again later.")

    static let serviceNotReady = FriendlyError(kind: .serviceNotReady, headline: "Anywhere isn’t ready",
                                               message: "Farside’s service couldn’t connect to this Mac yet.",
                                               fix: "Open Farside on your Mac and check it says Ready, then try again.")

    static let connectionLost = FriendlyError(kind: .connectionLost, headline: "The line went quiet",
                                              message: "The connection dropped, and retrying didn’t bring it back.",
                                              fix: "Check your signal, then try again.")

    static let sessionGlitch = FriendlyError(kind: .sessionGlitch, headline: "Ended to be safe",
                                             message: "The connection glitched, so Farside ended the session to keep your Mac safe.",
                                             fix: "Reconnect to pick up where you left off.")

    static func couch(_ reason: SessionModeRefusal) -> FriendlyError {
        switch reason {
        case .controlOff:
            FriendlyError(kind: .couchControlOff, headline: "Control is off", accent: "off", message: CouchCopy.controlOff,
                          fix: "Or connect with the picture to watch.", action: .connectWithPicture, secondary: .retry)
        case .screenRecording:
            FriendlyError(kind: .screenRecordingOff, headline: "Screen Recording is off", accent: "off",
                          message: CouchCopy.needsScreenRecording, fix: FriendlyError.screenRecordingOff.fix)
        case .displayUnavailable:
            FriendlyError(kind: .screenSharingOff, headline: "Mac display unavailable",
                          message: CouchCopy.displayUnavailable, fix: "Try showing the picture again.")
        case .notLocal:
            FriendlyError(kind: .couchNotLocal, headline: "Not on the same network", accent: "same",
                          message: CouchCopy.notLocal, fix: "Or connect with the picture instead.",
                          action: .connectWithPicture, secondary: .retry)
        }
    }

    static let couchProofFailures: Set<String> = [
        "No directly attached Wi-Fi or Ethernet link is available.",
        "The devices could not verify a directly attached local link.",
        "The local network changed. Reconnect to verify the route again.",
        "Local link proof could not start.",
        CouchCopy.phoneRefusedStatus
    ]

    static func forCouch(status: String, requestedCouch: Bool) -> FriendlyError? {
        requestedCouch && couchProofFailures.contains(status) ? couch(.notLocal) : nil
    }

    /// The service limited this attempt to the same network (contract §4: a non-closing
    /// `entitlement_required`) and it then failed to reach the Mac: say what Anywhere would change.
    static func forLocalOnly(_ error: FriendlyError, serviceAskedForAnywhere: Bool, hasPlan: Bool) -> FriendlyError {
        let unreached: Set<Kind> = [.unreachable, .connectionLost, .relayUnavailable, .needsPlan]
        guard error.kind == .needsPlan || (serviceAskedForAnywhere && unreached.contains(error.kind)) else { return error }
        return hasPlan ? .anywhereUnverified : .needsPlan
    }

    /// Maps a stopped connection's status. `previous` tells an approval timeout from any other.
    static func from(status: String, previous: String?, macName: String) -> FriendlyError? {
        let lower = status.lowercased()
        if lower == "mac unavailable: \(MacShareBlocker.screenRecordingOff.rawValue.lowercased())" { return .screenRecordingOff }
        if lower == "mac unavailable: \(MacShareBlocker.screenRecordingApproval.rawValue.lowercased())" { return .screenRecordingApproval }
        if lower.hasPrefix("connection timed out") {
            switch previous {
            case "Approve this phone on your Mac": return .approvalTimedOut
            case "Authenticating your Mac…": return .macNotResponding(macName)
            default: return .unreachable(macName)
            }
        }
        if lower.hasPrefix("connection service:") {
            if lower.contains("plan_required") || lower.contains("subscription_required") || lower.contains("entitlement_required") {
                return .needsPlan
            }
            if lower.contains("already_connected") || lower.contains("rate_limit") || lower.contains("registration_pending") { return .busy }
            if lower.contains("relay_unavailable") { return .relayUnavailable }
            if lower.contains("room_not_approved") || lower.contains("room_pending") || lower.contains("room_approval") {
                return .serviceNotReady
            }
            return .unreachable(macName)
        }
        if status == LocalNetworkAccess.deniedStatus { return .localNetworkOff }
        if lower.contains("declined") { return .declined }
        if lower.contains("keychain") { return .keychain }
        if lower.contains("invalid or expired") { return .codeRejected }
        if lower.hasPrefix("secure connection failed") || lower.contains("could not be authenticated")
            || lower.hasPrefix("pairing is not ready") { return .verifyFailed }
        if lower.hasPrefix("invalid control message") || lower.contains("old session message") { return .sessionGlitch }
        if lower.contains("requires a relay") || lower.contains("turn service") { return .relayUnavailable }
        if lower.hasPrefix("connection lost") { return .connectionLost }
        return nil
    }

    /// What the Mac said as it went away.
    static func from(presence: HostPresence, at time: String?) -> FriendlyError? {
        switch presence {
        case .sleeping: .napping(since: time)
        case .locked: .locked(since: time)
        case .switchedUser: .switchedUser(since: time)
        case .displayAsleep: nil
        }
    }

    /// Short plain wording for raw coordinator statuses on the Home card.
    static func cardStatus(_ raw: String) -> String {
        switch raw {
        case "Connecting securely…": "Connecting securely"
        case "Authenticating your Mac…": "Mac found · checking it’s yours"
        case "Connecting live desktop…": "Opening the picture"
        case "Connection interrupted · retrying…": "Reconnecting"
        default: raw
        }
    }
}

/// Full-screen friendly error: halftone art, a plain headline, one fix and one button.
struct FriendlyErrorView: View {
    let error: FriendlyError
    /// Replaces the action's title, e.g. "See the 7-day free trial" when the person is eligible.
    var primaryTitle: String?
    var primary: () -> Void
    var secondary: () -> Void = {}
    var close: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var appeared = false
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: error.scene)
                    .frame(height: verticalSizeClass == .compact ? 150 : 250)
                    .padding(.top, verticalSizeClass == .compact ? 0 : Farside.Space.xl)
                FarsideHeading("\(error.headline).", accent: error.accent, size: 34)
                    .padding(.top, Farside.Space.xs)
                messageText
                    .padding(.top, Farside.Space.s)
                if let tip = error.tip {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title = error.tipTitle { Text(title).farsideCaption(Farside.Palette.bone) }
                        Text(tip).font(.subheadline).foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Farside.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .farsidePlate(Farside.Radius.card, fill: .clear)
                    .padding(.top, Farside.Space.m)
                }
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.xl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            // Short messages sit in the middle of the space above the button instead of ending halfway down.
            .frame(minHeight: visibleHeight, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        } action: { _, height in
            visibleHeight = max(0, height)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Farside.Space.s) {
                Button(primaryTitle ?? error.action.title, action: primary)
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                    .accessibilityIdentifier("error.primary")
                if let second = error.secondary {
                    Button(second.title, action: secondary)
                        .buttonStyle(FarsideLinkButtonStyle())
                        .accessibilityIdentifier("error.secondary")
                }
                if let footnote = error.footnote {
                    Text(footnote).font(.footnote).foregroundStyle(Farside.Palette.ash).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.s)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(Farside.Palette.void)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(FarsideRoundButtonStyle())
                .accessibilityLabel("Close")
                .padding(.trailing, Farside.Space.s)
        }
        .background(FarsideBackground())
        .onAppear { appeared = true }
        .sensoryFeedback(.warning, trigger: appeared)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error.\(error.kind.rawValue)")
    }

    private var messageText: some View {
        let fix = Text(error.fix).foregroundStyle(Farside.Palette.bone).fontWeight(.medium)
        return Text("\(error.message) \(fix)")
            .font(.body)
            .foregroundStyle(Farside.Palette.ash)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Recovery remembers the attempted access path, rather than guessing from today's Wi-Fi.
/// A direct internet connection is still Anywhere; media transport is not an access policy.
enum PhoneRecovery {
    enum Route: Equatable { case localNetwork, anywhere, unknown }
    enum Failure: Equatable {
        case unavailable, invalidPairing, revokedPairing, needsPlan, unverifiedPlan, localPermission

        init(_ error: FriendlyError?) {
            switch error?.kind {
            case .codeRejected: self = .invalidPairing
            case .needsPlan: self = .needsPlan
            case .anywhereUnverified: self = .unverifiedPlan
            case .localNetworkOff: self = .localPermission
            default: self = .unavailable
            }
        }
    }
    static let key = "PocketDeskRouteAwareTroubleshooting"
    static let enabled = resolve(UserDefaults.standard)
    static func resolve(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
    static func route(localOnly: Bool, couch: Bool, serviceAccess: String?, hasPlan: Bool) -> Route {
        if localOnly || couch { return .localNetwork }
        if serviceAccess == "local" { return .localNetwork }
        if serviceAccess == "remote" || hasPlan { return .anywhere }
        return .unknown
    }
    static func mayPairAgain(_ failure: Failure, enabled: Bool) -> Bool {
        !enabled || failure == .invalidPairing || failure == .revokedPairing
    }
    static func showsSettings(route: Route, failure: Failure, enabled: Bool) -> Bool {
        !enabled || route == .localNetwork || failure == .localPermission
    }
    static func steps(mac: String, route: Route, failure: Failure, enabled: Bool) -> [String] {
        let common = ["\(mac) is awake and unlocked.", "Farside is running in the Mac’s menu bar."]
        guard enabled else {
            return common + ["Your \(DeviceWord.current) and Mac are on the same Wi-Fi.",
                             "Local Network is on for Farside in Settings.",
                             "Still stuck? Pair again from the Mac’s Farside menu."]
        }
        var steps = common
        switch route {
        case .localNetwork:
            steps += ["This device and your Mac share the same Wi-Fi or local network.",
                      "Local Network is on for Farside in Settings."]
        case .anywhere:
            steps += ["Both this device and your Mac have internet access.",
                      "In Farside Anywhere, check your plan or choose Restore Purchases."]
        case .unknown:
            steps += ["Nearby? Use your Mac’s Wi-Fi and allow Local Network for Farside in Settings.",
                      "Away? Both devices need internet access and an active Farside Anywhere plan."]
        }
        if failure == .needsPlan { steps += ["Away from your Mac? Open Farside Anywhere to see the plans."] }
        if failure == .unverifiedPlan { steps += ["Your plan couldn’t be confirmed. Check Farside Anywhere and try again."] }
        if mayPairAgain(failure, enabled: enabled) {
            steps += ["This pairing is no longer valid. At your Mac, open Farside and scan a fresh pairing code."]
        } else {
            steps += ["Keep your saved pairing. Try again after checking these steps."]
        }
        return steps
    }
    static func error(_ error: FriendlyError, route: Route, enabled: Bool) -> FriendlyError {
        guard enabled, route == .anywhere, error.kind == .unreachable else { return error }
        var result = error
        result.tipTitle = "Farside Anywhere"
        result.tip = "Both devices need internet access. Check your plan in Farside Anywhere, then try again."
        return result
    }
}

/// Plain next steps for the access path the last connection attempted.
struct TroubleshootSheet: View {
    var macName: String
    var route: PhoneRecovery.Route
    var failure: PhoneRecovery.Failure
    var retry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Farside.Space.l) {
                    FarsideHeading("Trouble connecting?", accent: "connecting", size: 30)
                    VStack(spacing: 0) {
                        let steps = PhoneRecovery.steps(mac: macName, route: route, failure: failure, enabled: PhoneRecovery.enabled)
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                            check(index + 1, text, last: index == steps.count - 1)
                        }
                    }
                    .farsidePlate()
                    if PhoneRecovery.showsSettings(route: route, failure: failure, enabled: PhoneRecovery.enabled) {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(FarsideLinkButtonStyle())
                    }
                }
                .padding(Farside.Space.l)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Try again") { dismiss(); retry() }
                    .buttonStyle(FarsidePrimaryButtonStyle())
                    .padding(.horizontal, Farside.Space.l)
                    .padding(.bottom, Farside.Space.s)
                    .frame(maxWidth: 560)
            }
            .background(FarsideBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .farsideSheet()
    }

    private func check(_ number: Int, _ text: String, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Farside.Space.s) {
            Text("\(number)")
                .font(Farside.Typeface.caption(.footnote).weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Farside.Space.m)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 52) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A friendly error inside a live session, on a plate over the (stale) picture: small art,
/// plain headline, and the one fix.
struct SessionIssueCard: View {
    let error: FriendlyError

    var body: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            FarsideHalftone(style: HalftoneStyle(cell: 4, dust: 0.03), scene: error.scene)
                .frame(height: 110)
                .clipShape(.rect(cornerRadius: Farside.Radius.control, style: .continuous))
            Text(error.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
            let fix = Text(error.fix).foregroundStyle(Farside.Palette.bone).fontWeight(.medium)
            Text("\(error.message) \(fix)")
                .font(.subheadline)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Farside.Space.m)
        .frame(maxWidth: 380, alignment: .leading)
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .padding(.horizontal, Farside.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote.issue.\(error.kind.rawValue)")
    }
}
