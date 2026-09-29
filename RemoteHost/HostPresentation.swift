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
        case .needsScreenRecording, .needsPhone, .unavailable, .approvalRequested: self = .attention
        case .ready, .starting, .pairing: self = .idle
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
        if let roundTripMs { parts.append(roundTripMs < 1 ? "<1 ms" : "\(roundTripMs) ms") }
        if let framesPerSecond { parts.append("\(framesPerSecond) fps") }
        return parts.joined(separator: " · ")
    }

    var spokenCaption: String {
        var parts: [String] = []
        switch route {
        case .direct: parts.append("Direct connection")
        case .relayed: parts.append("Relayed connection")
        case nil: break
        }
        if let roundTripMs { parts.append(roundTripMs < 1 ? "under 1 millisecond" : "\(roundTripMs) milliseconds") }
        if let framesPerSecond { parts.append("\(framesPerSecond) frames per second") }
        return parts.joined(separator: ", ")
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
    case allowPhone, declinePhone, finishSetup, pairPhone, showCode

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
        }
    }

    /// Opens another window, so the popover should close first.
    var leavesPopover: Bool {
        switch self {
        case .finishSetup, .pairPhone, .showCode: true
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

    static func make(
        for state: HostViewState,
        now: Date = Date(),
        timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> Self {
        switch state.status {
        case .controlling, .viewing:
            let viewOnly = state.status == .viewing
            return Self(
                mood: .live,
                headline: viewOnly ? "Connected · view only" : "Connected · sharing this Mac",
                title: viewOnly ? "Your iPhone is watching" : "Your iPhone is steering",
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
        case .pairing:
            return Self(
                mood: .calm, headline: "Pairing · waiting for a scan", title: "Waiting for your iPhone",
                caption: "The code is in the setup window", message: nil, symbol: "qrcode",
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
    static func furthestPage(for step: HostSetupStep) -> HostSetupPage {
        switch step {
        case .screenRecording, .accessibility: .permissions
        case .pairPhone: .pair
        case .done: .ready
        }
    }

    /// A first run starts with Hello; anything else opens where setup needs attention.
    static func initialPage(for state: HostViewState) -> HostSetupPage {
        let furthest = furthestPage(for: state.setupStep)
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
        case .pair: state.setupStep == .done
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
        switch page {
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
    enum ID: String, CaseIterable { case screenRecording, control, display, connection, phone, openAtLogin }
    enum Result: Equatable { case pass, waiting, optional, fail }
    enum Fix: Equatable {
        case openSettings(HostSystemSettingsPane)
        case allowControl, resumeSharing, tryAgain, pairPhone, openAtLogin
    }

    let id: ID
    var title: String
    var detail: String
    var result: Result
    var fix: Fix?

    static func checks(for state: HostViewState) -> [HostReadyCheck] {
        [screenRecording(state), control(state), display(state), connection(state), phone(state), openAtLogin(state)]
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
        case .approvalRequested:
            return Self(id: .connection, title: title, detail: "A phone is waiting for your approval", result: .waiting)
        case .paused:
            return Self(id: .connection, title: title, detail: "Sharing is off", result: .fail, fix: .resumeSharing)
        case .unavailable:
            return Self(id: .connection, title: title, detail: state.detail ?? "Couldn’t reach the connection",
                        result: .fail, fix: .tryAgain)
        case .needsScreenRecording:
            return Self(id: .connection, title: title, detail: "Needs Screen Recording first", result: .waiting)
        case .needsPhone:
            return Self(id: .connection, title: title, detail: "Starts once a phone is paired", result: .waiting)
        }
    }

    private static func phone(_ state: HostViewState) -> Self {
        state.hasPairedPhone
            ? Self(id: .phone, title: "iPhone paired", detail: "Only your approved phone can connect", result: .pass)
            : Self(id: .phone, title: "iPhone paired", detail: "No phone paired yet", result: .fail, fix: .pairPhone)
    }

    private static func openAtLogin(_ state: HostViewState) -> Self {
        state.openAtLogin
            ? Self(id: .openAtLogin, title: "Opens at login", detail: "Back by itself after a restart", result: .pass)
            : Self(id: .openAtLogin, title: "Opens at login", detail: "Recommended, so a restart doesn’t strand you",
                   result: .optional, fix: .openAtLogin)
    }
}
