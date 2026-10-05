import Foundation

// Pure mappings from host state to what the Farside UI says. No AppKit or SwiftUI here so the
// core test suite can check every state without rendering.

// MARK: Menu-bar mark

/// The menu-bar mark at a glance. Its tip turns ember only while a phone is connected.
enum HostMarkState: Equatable, CaseIterable {
    case idle, live, paused, attention

    init(status: HostStatus) {
        switch status {
        case .viewing, .controlling: self = .live
        case .paused: self = .paused
        case .needsScreenRecording, .captureNeedsApproval, .needsPhone, .unavailable, .approvalRequested: self = .attention
        case .ready, .starting, .reconnecting, .pairing: self = .idle
        }
    }
}

// MARK: Live session readout

/// Route, round trip and frame rate of the live session, read from the sender's periodic WebRTC
/// diagnostics line, e.g. "Direct · video/H264 · 60 fps · 14 ms network RTT · VideoToolbox".
/// Parts that are not measured yet ("fps pending") are left out rather than guessed.
struct HostSessionReadout: Equatable {
    enum Route: Equatable { case direct, relayed }

    var route: Route?
    var roundTripMs: Int?
    var framesPerSecond: Int?

    static func parse(_ diagnostics: String) -> HostSessionReadout? {
        var readout = HostSessionReadout()
        for part in diagnostics.components(separatedBy: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "Direct" {
                readout.route = .direct
            } else if part == "Relay" {
                readout.route = .relayed
            } else if part.hasSuffix(" fps"), let value = Double(part.dropLast(4)), value.isFinite, value >= 0 {
                readout.framesPerSecond = Int(value.rounded())
            } else if part.hasSuffix(" ms network RTT"),
                      let value = Double(part.dropLast(15)), value.isFinite, value >= 0 {
                readout.roundTripMs = Int(value.rounded())
            }
        }
        return readout == HostSessionReadout() ? nil : readout
    }

    /// "Direct · 14 ms · 60 fps", only the measured parts.
    var caption: String {
        var parts: [String] = []
        switch route {
        case .direct: parts.append("Direct")
        case .relayed: parts.append("Relayed")
        case nil: break
        }
        if let roundTripMs { parts.append(roundTripMs < 1 ? "<1 ms RTT" : "\(roundTripMs) ms RTT") }
        if let framesPerSecond { parts.append("\(framesPerSecond) fps sent") }
        return parts.joined(separator: " · ")
    }

    var spokenCaption: String {
        var parts: [String] = []
        switch route {
        case .direct: parts.append("Direct connection")
        case .relayed: parts.append("Relayed connection")
        case nil: break
        }
        if let roundTripMs { parts.append(HostMetricCopy.spokenRoundTrip(roundTripMs)) }
        if let framesPerSecond { parts.append(HostMetricCopy.spokenSending(framesPerSecond)) }
        return parts.joined(separator: ", ")
    }
}

/// Process-start rollback switches; the layout experiment stays off until device A/B.
enum HostPopoverPolicy {
    static let bounded = bounded(defaults: .standard)
    static let scopedControls = scopedControls(defaults: .standard)
    static let guestAudience = guestAudience(defaults: .standard)

    static func bounded(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "farsideBoundedPopoverDisabled") != nil
            ? !defaults.bool(forKey: "farsideBoundedPopoverDisabled") : false
    }

    static func scopedControls(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: "farsideScopedPopoverControlsDisabled")
    }

    static func guestAudience(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: "farsidePopoverGuestAudienceDisabled")
    }

    static func maximumHeight(visibleHeight: Double) -> Double {
        min(640, max(0, visibleHeight - 24))
    }

    static func headerHeight(content: Double, actions: Double, maximum: Double) -> Double {
        min(max(0, content), max(0, maximum - 96 - actions))
    }

    static func detailHeight(content: Double, pinned: Double, maximum: Double) -> Double {
        min(max(0, content), max(0, maximum - pinned))
    }

    static func controlsDisabled(scoped: Bool, enabled: Bool = scopedControls) -> Bool {
        enabled && scoped
    }

    static func audience(_ rows: [HostGuestRow], enabled: Bool = guestAudience) -> String? {
        guard enabled, !rows.isEmpty else { return nil }
        // Existing status distinguishes issued grants from a link still being created. It cannot
        // prove live media: a peer may still be connecting or paused by the guest budget.
        let approved = rows.filter(hasVideoAccess).count
        let pending = rows.filter(\.pending).count
        var parts: [String] = []
        if approved > 0 { parts.append(approved == 1 ? "1 guest has video access" : "\(approved) guests have video access") }
        if pending > 0 { parts.append(pending == 1 ? "1 guest needs approval" : "\(pending) guests need approval") }
        if parts.isEmpty { parts.append("Guest setup") }
        return parts.joined(separator: " · ")
    }

    static func hasVideoAccess(_ row: HostGuestRow) -> Bool {
        row.status == "Approved · connecting" || row.status == "Viewing · video only"
    }

    static func guestStatus(_ row: HostGuestRow) -> String {
        if row.pending { return "Guest needs approval" }
        if hasVideoAccess(row) { return "Video access approved" }
        return row.linkReady ? "Guest link ready" : "Preparing guest link"
    }

    static func scopeCaption(_ state: HostViewState) -> String? {
        guard state.captureScopeViewOnly else { return nil }
        let name = state.captureScopes.first { $0.id == state.selectedCaptureScopeID }?.name
            ?? "Selected content unavailable"
        return "App/window sharing is view only. \(name)"
    }
}

enum HostMetricCopy {
    static let roundTripTitle = "Network RTT"
    static let sendingTitle = "Sending FPS"
    static let roundTripHelp = "Network round-trip time: a message going to the other device and back. Picture and input processing add time."
    static let sendingHelp = "Video frames sent by this Mac each second. The receiving device may show fewer frames."
    static func spokenRoundTrip(_ value: Int?) -> String {
        value.map { "Network round-trip time: \($0 < 1 ? "under 1" : String($0)) milliseconds" }
            ?? "Network round-trip time: not measured yet"
    }
    static func spokenSending(_ value: Int?) -> String {
        value.map { "Sending frame rate: \($0) frames per second" } ?? "Sending frame rate: not measured yet"
    }
}

// MARK: Timed pause

/// "Pause 10 min": sharing stops now and comes back by itself when the pause ends, unless the
/// user resumes or stops sharing first. Only the most recent pause may resume sharing.
struct HostTimedPause: Equatable {
    static let standard: TimeInterval = 10 * 60

    private(set) var resumesAt: Date?

    @discardableResult
    mutating func begin(at now: Date, duration: TimeInterval = standard) -> Date {
        let resumesAt = now.addingTimeInterval(max(1, duration))
        self.resumesAt = resumesAt
        return resumesAt
    }

    mutating func cancel() { resumesAt = nil }

    func isActive(at now: Date) -> Bool { resumesAt.map { $0 > now } ?? false }

    /// A timer may resume sharing only if its pause is still the latest one.
    func isCurrent(_ scheduledFor: Date) -> Bool { resumesAt == scheduledFor }
}

// MARK: Popover

enum HostPopoverAction: Equatable {
    case pause, stopSharing, resumeNow, resumeSharing, tryAgain
    case allowPhone, declinePhone, finishSetup, pairPhone, showCode, openScreenRecording

    var title: String {
        switch self {
        case .pause: "Pause 10 min"
        case .stopSharing: "Stop Sharing"
        case .resumeNow: "Resume Now"
        case .resumeSharing: "Resume Sharing"
        case .tryAgain: "Try Again"
        case .allowPhone: "Allow"
        case .declinePhone: "Decline"
        case .finishSetup: "Finish Setup…"
        case .pairPhone: "Pair a Phone…"
        case .showCode: "Show Code…"
        case .openScreenRecording: "Open Settings…"
        }
    }

    /// Stable name for UI automation; titles may change with copy edits.
    var identifier: String {
        switch self {
        case .pause: "pause"
        case .stopSharing: "stopSharing"
        case .resumeNow: "resumeNow"
        case .resumeSharing: "resumeSharing"
        case .tryAgain: "tryAgain"
        case .allowPhone: "allowPhone"
        case .declinePhone: "declinePhone"
        case .finishSetup: "finishSetup"
        case .pairPhone: "pairPhone"
        case .showCode: "showCode"
        case .openScreenRecording: "openScreenRecording"
        }
    }

    /// Opens another window, so the popover should close first.
    var leavesPopover: Bool {
        switch self {
        case .finishSetup, .pairPhone, .showCode, .openScreenRecording: true
        default: false
        }
    }
}

struct HostPopoverPresentation: Equatable {
    enum Mood: Equatable { case live, calm, paused, attention }
    enum Emphasis: Equatable { case plate, primary, ember }

    var mood: Mood
    /// The strip caption, e.g. "Connected · sharing this Mac".
    var headline: String
    /// Who or what, e.g. "Your iPhone is steering".
    var title: String
    /// Short technical line under the title, e.g. "Direct · 14 ms · 60 fps".
    var caption: String?
    var spokenCaption: String?
    /// A plain sentence, when the state needs explaining.
    var message: String?
    var symbol: String
    var showsSessionToggles: Bool
    /// Left to right; the last one is the main action.
    var actions: [HostPopoverAction]

    /// Bone for the main action, a plate for the rest, ember only for ending something live.
    func emphasis(of action: HostPopoverAction) -> Emphasis {
        if action == .stopSharing { return mood == .live ? .ember : .plate }
        if action == .pause || action == .declinePhone { return .plate }
        return action == actions.last ? .primary : .plate
    }

    /// The button Return presses. For an unknown phone that is Decline, so Return never lets a
    /// phone in (D39); otherwise the bone main action, if there is one.
    var defaultAction: HostPopoverAction? {
        if actions.contains(.declinePhone) { return .declinePhone }
        guard let last = actions.last, emphasis(of: last) == .primary else { return nil }
        return last
    }

    static func make(
        for state: HostViewState,
        now: Date = Date(),
        timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> Self {
        switch state.status {
        case .controlling, .viewing:
            let viewOnly = state.status == .viewing
            let headline = state.couchMode
                ? (viewOnly ? "Couch mode · control is off" : "Couch mode · no picture shared")
                : (viewOnly ? "Connected · view only" : "Connected · sharing this Mac")
            let title = state.couchMode
                ? (viewOnly ? "\(state.phoneName) is connected" : "\(state.phoneName) is steering")
                : (viewOnly ? "\(state.phoneName) is watching" : "\(state.phoneName) is steering")
            return Self(
                mood: .live,
                headline: headline,
                title: title,
                caption: state.session.map(\.caption).flatMap { $0.isEmpty ? nil : $0 } ?? "Measuring the connection",
                spokenCaption: state.session.map(\.spokenCaption),
                message: state.availability == .displayAsleep
                    ? "The display is asleep. Your iPhone can wake it." : state.detail,
                symbol: "iphone.gen3",
                showsSessionToggles: true,
                actions: [.pause, .stopSharing]
            )
        case .ready:
            return Self(
                mood: .calm, headline: "Ready · waiting for your iPhone", title: "No one is connected",
                caption: "Open Farside on your iPhone", message: state.detail, symbol: "iphone.gen3",
                showsSessionToggles: true, actions: [.pause, .stopSharing]
            )
        case .starting:
            return Self(
                mood: .calm, headline: "Getting ready", title: "Checking the connection",
                caption: "This takes a few seconds", message: state.detail,
                symbol: "antenna.radiowaves.left.and.right", showsSessionToggles: true, actions: [.stopSharing]
            )
        case .reconnecting:
            return Self(
                mood: .calm, headline: "Reconnecting to the service", title: "Reconnecting to Farside service…",
                caption: "Your iPhone can’t reach this Mac until it’s back", message: state.detail,
                symbol: "arrow.triangle.2.circlepath", showsSessionToggles: true, actions: [.stopSharing]
            )
        case .pairing:
            return Self(
                mood: .calm, headline: "Pairing · waiting for a scan", title: "Waiting for your iPhone",
                caption: "Scan it in Farside on your iPhone", message: nil, symbol: "qrcode",
                showsSessionToggles: false, actions: [.stopSharing, .showCode]
            )
        case .approvalRequested:
            return Self(
                mood: .attention, headline: "A phone wants to connect", title: "Is this your phone?",
                caption: "It just scanned your code",
                message: state.allowControl
                    ? "Once allowed, it can see this screen and use the mouse and keyboard. Allow it only if it’s the phone in your hand."
                    : "Once allowed, it can see this screen. Allow it only if it’s the phone in your hand.",
                symbol: "questionmark", showsSessionToggles: false, actions: [.declinePhone, .allowPhone]
            )
        case .paused:
            if let resumesAt = state.pausedUntil, resumesAt > now {
                let time = timeText(resumesAt)
                return Self(
                    mood: .paused, headline: "Paused · back at \(time)", title: "Sharing is paused",
                    caption: "Your iPhone can’t connect until then", message: nil, symbol: "pause",
                    showsSessionToggles: false, actions: [.resumeNow]
                )
            }
            return Self(
                mood: .paused, headline: "Sharing is off", title: "Sharing is off",
                caption: "Your iPhone can’t connect", message: nil, symbol: "pause",
                showsSessionToggles: false, actions: [.resumeSharing]
            )
        case .unavailable where state.crashLoopStopped:
            return Self(
                mood: .attention, headline: "Stopped after repeated crashes", title: "Farside stopped itself",
                caption: "It quit 3 times in 5 minutes",
                message: "Sharing is paused so it can’t keep crashing. Try again when you’re ready; Copy Diagnostics in Settings helps find out why.",
                symbol: "exclamationmark.arrow.circlepath", showsSessionToggles: false, actions: [.tryAgain]
            )
        case .unavailable:
            let note: (headline: String, title: String, caption: String?, symbol: String) = switch state.availability {
            case .locked: ("This Mac is locked", "This Mac is locked", "Sharing resumes when it’s unlocked", "lock")
            case .asleep: ("This Mac went to sleep", "This Mac went to sleep", "Sharing resumes when it wakes", "moon.zzz")
            case .switchedUser: ("Another user is on", "Someone else is using this Mac",
                                 "Sharing resumes when you switch back", "person.2")
            case .displayAsleep, nil: ("Needs attention", "Sharing stopped", nil, "exclamationmark")
            }
            return Self(
                mood: .attention, headline: note.headline, title: note.title, caption: note.caption,
                message: note.caption == nil ? (state.detail ?? "Check your internet connection, then try again.") : nil,
                symbol: note.symbol, showsSessionToggles: false, actions: [.tryAgain]
            )
        case .captureNeedsApproval:
            return Self(
                mood: .attention, headline: "Approve screen recording",
                title: HostStatus.captureNeedsApproval.title,
                caption: "Your iPhone is told why it can’t connect",
                message: HostCaptureApprovalCopy.steps(listName: state.appListName, macOSMajor: state.macOSMajor),
                symbol: "rectangle.dashed.badge.record", showsSessionToggles: false,
                actions: [.tryAgain, .openScreenRecording]
            )
        case .needsScreenRecording:
            return Self(
                mood: .attention, headline: "Needs Screen Recording", title: "Farside can’t see this screen",
                caption: "Allow Screen Recording to share it", message: nil, symbol: "rectangle.dashed.badge.record",
                showsSessionToggles: false, actions: [.finishSetup]
            )
        case .needsPhone:
            return Self(
                mood: .attention, headline: "No phone paired yet", title: "Pair your iPhone",
                caption: "It takes about a minute", message: nil, symbol: "iphone.gen3",
                showsSessionToggles: false, actions: [.pairPhone]
            )
        }
    }
}

// MARK: Setup flow

/// Pages of the setup window. The model decides how far setup may go; these pages let the user
/// look back without losing that.
enum HostSetupPage: Int, CaseIterable, Comparable, Identifiable {
    case hello, permissions, pair, ready

    var id: Int { rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .hello: "Hello"
        case .permissions: "Permissions"
        case .pair: "Pair your phone"
        case .ready: "Ready check"
        }
    }
}

enum HostSetupFlow {
    static func first60PairingIsDeferred(_ state: HostViewState) -> Bool {
        state.first60SetupPending && state.pairingDeferred && !state.hasPairedPhone
    }

    static func first60Page(for state: HostViewState) -> HostSetupPage {
        if !state.hasPairedPhone || state.pairingRequested {
            return state.pairingDeferred ? .ready : .pair
        }
        if !state.screenRecording.isGranted || (!state.accessibility.isGranted && !state.accessibilitySkipped && state.allowControl) {
            return .permissions
        }
        return .ready
    }

    static func visiblePages(first60: Bool) -> [HostSetupPage] {
        first60 ? [.pair, .permissions, .ready] : HostSetupPage.allCases
    }

    static func furthestPage(for step: HostSetupStep, pairingDeferred: Bool = false) -> HostSetupPage {
        switch step {
        case .screenRecording, .accessibility: .permissions
        case .pairPhone: pairingDeferred ? .ready : .pair
        case .done: .ready
        }
    }

    /// A first run starts with Hello; anything else opens where setup needs attention.
    static func initialPage(for state: HostViewState) -> HostSetupPage {
        if state.first60SetupPending { return first60Page(for: state) }
        let furthest = furthestPage(for: state.setupStep, pairingDeferred: state.pairingDeferred)
        if furthest == .permissions, !state.screenRecording.isGranted, !state.accessibility.isGranted,
           !state.hasPairedPhone {
            return .hello
        }
        return furthest
    }

    static func canContinue(from page: HostSetupPage, state: HostViewState) -> Bool {
        switch page {
        case .hello: true
        case .permissions: state.setupStep > .accessibility
        case .pair: state.setupStep == .done || (state.setupStep == .pairPhone && state.pairingDeferred)
        case .ready: false
        }
    }

    /// Losing a permission sends the user back to it; finishing pairing moves on to the check.
    static func page(afterStepChangeFrom old: HostSetupStep, to new: HostSetupStep,
                     current: HostSetupPage) -> HostSetupPage {
        let furthest = furthestPage(for: new)
        if current > furthest { return furthest }
        if old == .pairPhone, new == .done, current == .pair { return .ready }
        return current
    }

    static func grantedPermissions(_ state: HostViewState) -> Int {
        (state.screenRecording.isGranted ? 1 : 0) + (state.accessibility.isGranted ? 1 : 0)
    }

    static func isComplete(_ page: HostSetupPage, state: HostViewState, current: HostSetupPage) -> Bool {
        if state.first60SetupPending {
            switch page {
            case .hello: return true
            case .pair: return state.hasPairedPhone
            case .permissions: return state.screenRecording.isGranted && (state.accessibility.isGranted || state.accessibilitySkipped || !state.allowControl)
            case .ready: return false
            }
        }
        return switch page {
        case .hello: current > .hello || state.setupStep > .screenRecording
        case .permissions: state.setupStep > .accessibility
        case .pair: state.hasPairedPhone && !state.pairingRequested
        case .ready: false
        }
    }

    /// Filled dots out of four per page, so progress moves inside a page too.
    static func progressDots(page: HostSetupPage, state: HostViewState) -> Int {
        let within: Int = switch page {
        case .hello: 0
        case .permissions: grantedPermissions(state) + (canContinue(from: .permissions, state: state) ? 1 : 0)
        case .pair:
            switch state.pairing {
            case .showingCode: 1
            case .awaitingApproval: 2
            default: canContinue(from: .pair, state: state) ? 3 : 0
            }
        case .ready: min(3, HostReadyCheck.checks(for: state).filter { $0.result == .pass }.count / 2)
        }
        return page.rawValue * 4 + min(3, within)
    }

    static func progressCaption(page: HostSetupPage, state: HostViewState) -> String {
        if state.first60SetupPending && page == .ready {
            if first60PairingIsDeferred(state) { return "Continue from the menu bar" }
            return state.first60RemoteDoneAvailable ? "Click Done from your device" : "Finish here when you’re ready"
        }
        switch page {
        case .hello:
            return "About a minute"
        case .permissions:
            let granted = grantedPermissions(state)
            if granted == 2 { return "Both granted" }
            if state.screenRecording.isGranted, state.accessibilitySkipped { return "View only for now" }
            return "\(granted) of 2 granted"
        case .pair:
            switch state.pairing {
            case .awaitingApproval: return "Waiting for you"
            case .showingCode: return "Waiting for a scan"
            case .expired: return "Code expired"
            default: return canContinue(from: .pair, state: state) ? "Paired" : "Getting a code"
            }
        case .ready:
            let checks = HostReadyCheck.checks(for: state)
            return "\(checks.filter { $0.result == .pass }.count) of \(checks.count) checks pass"
        }
    }
}

// MARK: Ready check

/// A check made against live state, never a promise: each row passes only when that thing is
/// true on this Mac right now.
struct HostReadyCheck: Equatable, Identifiable {
    enum ID: String, CaseIterable { case screenRecording, control, display, connection, phone, backgroundChoices }
    enum Result: Equatable { case pass, waiting, optional, fail }
    enum Fix: Equatable {
        case openSettings(HostSystemSettingsPane)
        case allowControl, resumeSharing, tryAgain, pairPhone, reviewChoices, openLoginItems
    }

    let id: ID
    var title: String
    var detail: String
    var result: Result
    var fix: Fix?

    static func checks(for state: HostViewState) -> [HostReadyCheck] {
        [screenRecording(state), control(state), display(state), connection(state), phone(state), backgroundChoices(state)]
    }

    /// Ready means nothing failed and nothing is still being checked; optional items may remain.
    static func isReady(_ checks: [HostReadyCheck]) -> Bool {
        !checks.contains { $0.result == .fail || $0.result == .waiting }
    }

    private static func screenRecording(_ state: HostViewState) -> Self {
        state.screenRecording.isGranted
            ? Self(id: .screenRecording, title: "Screen Recording", detail: "Your iPhone can see the screen", result: .pass)
            : Self(id: .screenRecording, title: "Screen Recording", detail: "Farside can’t see the screen yet",
                   result: .fail, fix: .openSettings(.screenRecording))
    }

    private static func control(_ state: HostViewState) -> Self {
        let title = "Mouse and keyboard"
        if !state.accessibility.isGranted {
            return Self(id: .control, title: title, detail: "View only until Accessibility is allowed",
                        result: .optional, fix: .openSettings(.accessibility))
        }
        if !state.allowControl {
            return Self(id: .control, title: title, detail: "View only · control is turned off",
                        result: .optional, fix: .allowControl)
        }
        return Self(id: .control, title: title, detail: "Taps become clicks, typing becomes typing", result: .pass)
    }

    private static func display(_ state: HostViewState) -> Self {
        if let name = state.selectedDisplayName {
            return Self(id: .display, title: "A display to share", detail: "Sharing \(name)", result: .pass)
        }
        if !state.screenRecording.isGranted {
            return Self(id: .display, title: "A display to share", detail: "Needs Screen Recording first", result: .waiting)
        }
        return state.status == .unavailable
            ? Self(id: .display, title: "A display to share", detail: "No display found to share",
                   result: .fail, fix: .tryAgain)
            : Self(id: .display, title: "A display to share", detail: "Looking for displays", result: .waiting)
    }

    private static func connection(_ state: HostViewState) -> Self {
        let title = "Connection"
        switch state.status {
        case .ready:
            return Self(id: .connection, title: title, detail: "Listening for your iPhone", result: .pass)
        case .viewing, .controlling:
            return Self(id: .connection, title: title, detail: "Your iPhone is connected now", result: .pass)
        case .starting, .pairing:
            return Self(id: .connection, title: title, detail: "Checking the connection", result: .waiting)
        case .reconnecting:
            return Self(id: .connection, title: title, detail: "Reconnecting to Farside service", result: .waiting)
        case .approvalRequested:
            return Self(id: .connection, title: title, detail: "A phone is waiting for your approval", result: .waiting)
        case .paused:
            return Self(id: .connection, title: title, detail: "Sharing is off", result: .fail, fix: .resumeSharing)
        case .unavailable:
            return Self(id: .connection, title: title, detail: state.detail ?? "Couldn’t reach the connection",
                        result: .fail, fix: .tryAgain)
        case .needsScreenRecording:
            return Self(id: .connection, title: title, detail: "Needs Screen Recording first", result: .waiting)
        case .captureNeedsApproval:
            return Self(id: .connection, title: title, detail: HostStatus.captureNeedsApproval.title,
                        result: .fail, fix: .openSettings(.screenRecording))
        case .needsPhone:
            return Self(id: .connection, title: title, detail: "Starts once a phone is paired", result: .waiting)
        }
    }

    private static func phone(_ state: HostViewState) -> Self {
        if state.hasPairedPhone {
            return Self(id: .phone, title: "iPhone paired", detail: "Only your approved phone can connect", result: .pass)
        }
        return state.pairingDeferred
            ? Self(id: .phone, title: "iPhone paired", detail: "Skipped for now · pair from the menu bar",
                   result: .optional, fix: .pairPhone)
            : Self(id: .phone, title: "iPhone paired", detail: "No phone paired yet", result: .fail, fix: .pairPhone)
    }

    /// Choosing is required, even choosing off. Once chosen, the row says what macOS is doing now.
    private static func backgroundChoices(_ state: HostViewState) -> Self {
        let title = "Login and keep awake"
        if state.consentPending {
            return Self(id: .backgroundChoices, title: title, detail: "Choose both before you head out",
                        result: .fail, fix: .reviewChoices)
        }
        if state.openAtLogin {
            switch state.loginItem {
            case .needsApproval:
                return Self(id: .backgroundChoices, title: title, detail: "Open at login needs approval in System Settings",
                            result: .optional, fix: .openLoginItems)
            case .off, .unavailable:
                return Self(id: .backgroundChoices, title: title, detail: "Open at login isn’t registered",
                            result: .optional, fix: .reviewChoices)
            case .on:
                break
            }
        }
        return Self(id: .backgroundChoices, title: title,
                    detail: HostConsentCopy.summary(opensAtLogin: state.loginItem == .on, keepAwake: state.keepAwake,
                                                    pausedOnBattery: state.keepAwakePausedOnBattery),
                    result: .pass, fix: .reviewChoices)
    }
}

// MARK: Reliability and privacy rows

/// What a login item or the watchdog helper is doing, in plain words. Never "on" unless macOS
/// says it is enabled.
enum HostBackgroundItemCopy {
    /// The saved choice first, then what macOS has registered for it.
    static func loginSubtitle(wanted: Bool, state: HostBackgroundItemState) -> String {
        switch (wanted, state) {
        case (true, .on): "On · registered"
        case (true, .needsApproval): "On · needs approval in System Settings"
        case (true, .off): "On · not registered yet. Switch off and on to retry"
        case (true, .unavailable): "On · move Farside to Applications first"
        case (false, .on), (false, .needsApproval): "Off · still listed in System Settings"
        case (false, _): "Off"
        }
    }

    static func recoverySubtitle(_ state: HostBackgroundItemState) -> String {
        switch state {
        case .on: "Reopens after a crash or freeze; your deliberate Quit stays closed"
        case .off: "Farside stays closed if it crashes"
        case .needsApproval: "Waiting for approval in System Settings"
        case .unavailable: "Move Farside to Applications first"
        }
    }
}

/// The one-time explanation of open at login and keep-awake, asked again when its version rises.
enum HostConsentCopy {
    static let intro = "Your current settings are filled in. Nothing changes until Continue."
    static let loginTitle = "Open at login"
    static let loginBody = "Farside opens by itself when you log in, so your iPhone can reach this Mac without you "
        + "opening Farside first. macOS may show a notification that a login item was added. "
        + "Change it later in Farside’s Settings or in System Settings."
    static let keepAwakeTitle = "Keep this Mac awake while sharing"
    static let keepAwakeBody = "While sharing is on and no phone is connected, Farside stops this Mac from going to "
        + "sleep when it’s idle, so your iPhone can still reach it. The screen still turns off as usual. "
        + "On battery this pauses until you plug in."
    static let alwaysTrue = "Either way, while your iPhone is connected and not paused, Farside keeps the screen on. "
        + "Farside never unlocks this Mac: if it locks, sharing stops until someone unlocks it here. "
        + "Closing the lid or choosing Sleep still sleeps it."
    static let confirm = "Continue"
    static let keepCurrent = "Keep current settings"

    static func summary(opensAtLogin: Bool, keepAwake: Bool, pausedOnBattery: Bool = false) -> String {
        let login = opensAtLogin ? "Opens at login" : "Opens when you open it"
        let awake = !keepAwake ? "sleeps as usual" : pausedOnBattery ? "keep-awake paused on battery" : "stays awake while sharing"
        return login + " · " + awake
    }
}

/// The consent sheet's switches: the person's current choices, so confirming changes nothing unasked.
struct HostConsentChoices: Equatable {
    var openAtLogin: Bool
    var keepAwake: Bool

    init(openAtLogin: Bool, keepAwake: Bool) {
        self.openAtLogin = openAtLogin
        self.keepAwake = keepAwake
    }

    init(_ state: HostViewState) {
        self.init(openAtLogin: state.openAtLogin, keepAwake: state.keepAwake)
    }
}

enum HostKeepAwakeCopy {
    static func subtitle(pausedOnBattery: Bool) -> String {
        pausedOnBattery
            ? "Paused on battery · resumes on power. While your iPhone is connected and not paused, the screen still stays on. Lid close, lock and Sleep still apply."
            : "Stops idle sleep while sharing with no phone connected; the screen still sleeps. While your iPhone is connected and not paused, the screen always stays on. Pauses on battery. Lid close, lock and Sleep still apply."
    }
}

/// What to do at the Mac when macOS paused the capture. Farside shares again by itself once allowed.
enum HostCaptureApprovalCopy {
    static func steps(listName: String, macOSMajor: Int) -> String {
        "If macOS asks whether “\(listName)” may keep recording the screen, allow it. No prompt? "
            + HostPermissionCopy.switchOn(.screenRecording, listName: listName, macOSMajor: macOSMajor)
            + " Farside shares again by itself."
    }

    /// Setup's line after a macOS update turned permissions off.
    static func afterUpdate(_ missing: [HostSystemSettingsPane], macOSMajor: Int) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map { $0.title(macOSMajor: macOSMajor) }
        return "macOS was updated and turned off \(names.joined(separator: " and ")). Switch "
            + (missing.count == 1 ? "it" : "them") + " back on below."
    }
}

enum HostMenuBarIconCopy {
    static func subtitle(shown: Bool) -> String {
        shown ? "Hide the icon to remove quick controls. Farside keeps running and sharing; reopen it from Applications"
            : "Hidden. Farside keeps running and sharing; open it from Applications to get here"
    }
}

enum HostCurtainCopy {
    static func subtitle(for state: HostViewState) -> String {
        if state.captureScopeViewOnly { return "Not used while sharing a single window or app" }
        if state.curtainNeedsAccessibility { return "Needs Accessibility, so Esc can always lift it" }
        if let status = state.curtainStatus { return status }
        return state.privacyCurtain
            ? "On by default. Your phone still sees everything. Esc three times at this Mac shows it"
            : "Off: anyone at the Mac can watch what the phone does"
    }
}
