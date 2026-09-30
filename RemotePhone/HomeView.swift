import SwiftUI

struct PhoneRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @StateObject private var onboarding = OnboardingFlow()
    @AppStorage(HomeView.lastReachedKey) private var lastReachedAt = 0.0
    /// A live session stays on screen while it reconnects by itself, so zoom and pan survive a blip.
    @State private var sessionHeld = false

    private var showsSession: Bool {
        connection.connected || connection.remoteVideo != nil
            || (sessionHeld && MacStatus(connection.status).tone == .busy)
    }

    var body: some View {
        Group {
            if showsSession {
                // A held background session keeps its viewport; the overlay hides every remote pixel.
                NativeSessionView(model: model, connection: connection, offlineLayoutCheck: false)
                    .overlay {
                        if model.contentConcealed { ConcealedRemoteView(model: model, connection: connection) }
                    }
            } else if model.contentConcealed {
                ConcealedRemoteView(model: model, connection: connection)
            } else if LaunchOptions.layoutCheck {
                NativeSessionView(model: model, connection: connection, offlineLayoutCheck: true)
            } else {
                HomeView(model: model, connection: connection, onboarding: onboarding)
            }
        }
        .fullScreenCover(item: $onboarding.step) { step in
            switch step {
            case .priming(let kind):
                PermissionPrimingView(kind: kind, onContinue: onboarding.primingFinished)
            case .coach:
                GestureCoachView(onFinish: onboarding.coachFinished)
            }
        }
        .farsideSystemRoutes(model: model, onboarding: onboarding)
        .onChange(of: connection.connected) { _, connected in
            if connected {
                lastReachedAt = Date().timeIntervalSince1970
                sessionHeld = true
            }
        }
        .onChange(of: connection.status) { _, status in
            if !connection.connected && MacStatus(status).tone != .busy { sessionHeld = false }
        }
        .modifier(E2EStateProbeModifier())
    }
}

/// Debug-only launch switches used by UI tests and simulator screenshots.
enum LaunchOptions {
    static var layoutCheck: Bool { has("--ui-layout-check") }
    static var demoMacName: String? { has("--ui-demo-mac") ? "MacBook Air" : nil }
    static var viewportOverride: ViewportMode? {
        has("--ui-viewport-fit") ? .fit : has("--ui-viewport-fill") ? .fill : nil
    }
    static var touchModeOverride: TouchInputMode? {
        has("--ui-touch-direct") ? .direct : has("--ui-touch-trackpad") ? .trackpad : nil
    }
    /// UI tests, screenshots and E2E harness runs never get surprise onboarding screens
    /// (permission priming, gesture coach).
    static var suppressesOnboarding: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-") || $0 == E2E.launchArgument }
        #else
        false
        #endif
    }

    static func has(_ argument: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    static func value(_ prefix: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        #else
        nil
        #endif
    }
}

struct HomeView: View {
    static let lastReachedKey = "lastReachedAt"

    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @ObservedObject var onboarding: OnboardingFlow
    @State private var showDetails = false
    @State private var showTroubleshoot = false
    @State private var confirmForget = false
    @State private var friendlyError: FriendlyError?
    @State private var lastFailure: FriendlyError?
    @State private var shownNotice: String?
    @State private var pairedInSheet = false
    @State private var contactRipples: [HalftoneRipple] = []
    @State private var artSize: CGSize = .zero
    @State private var showPaywall = false
    @State private var showServerData = false
    @State private var showLegal = false
    @ObservedObject private var anywhere = AnywhereStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HomeView.lastReachedKey) private var lastReachedAt = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var macName: String? { connection.invitation?.name ?? LaunchOptions.demoMacName }
    private var status: MacStatus { MacStatus(connection.status) }
    private var covered: Bool { model.pairingEntry != nil || friendlyError != nil || onboarding.step != nil || showDetails || showTroubleshoot || showPaywall || showServerData || showLegal }

    var body: some View {
        GeometryReader { proxy in
            if verticalSizeClass == .compact {
                // Landscape phone: art on the left, the Mac and Connect always in view on the right.
                HStack(alignment: .top, spacing: Farside.Space.l) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        gapArt(fullBleed: false)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    ScrollView {
                        homeColumn.padding(.top, Farside.Space.s)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("phone.home")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, Farside.Space.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        gapArt(fullBleed: true)
                        homeColumn
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, Farside.Space.m)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("phone.home")
            }
        }
        .background(FarsideBackground())
        .sheet(item: $model.pairingEntry, onDismiss: pairingDismissed) { entry in
            PairingSheet(model: model, entry: entry, replacing: connection.invitation?.name) { pairedInSheet = true }
        }
        .sheet(isPresented: $showDetails) {
            ConnectionDetailsSheet(connection: connection)
        }
        .sheet(isPresented: $showTroubleshoot) {
            TroubleshootSheet(macName: macName ?? "Your Mac", retry: connect)
        }
        .fullScreenCover(item: $friendlyError) { error in
            FriendlyErrorView(error: error, primaryTitle: primaryTitle(for: error), primary: { resolve(error, action: error.action) },
                              secondary: { if let second = error.secondary { resolve(error, action: second) } },
                              close: { friendlyError = nil })
        }
        .sheet(isPresented: $showPaywall) {
            AnywherePaywallView(store: anywhere, access: AnywhereAccess.shared)
                .farsideSheet()
        }
        .sheet(isPresented: $showLegal) { LegalNoticesView() }
        .sheet(isPresented: $showServerData) {
            ServerDataRemovalView(connection: connection, access: AnywhereAccess.shared).farsideSheet()
        }
        .confirmationDialog("Forget this Mac locally?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) {
                connection.revoke()
                lastReachedAt = 0
                lastFailure = nil
            }
        } message: {
            Text("This removes local pairing only. Server Data removes your Anywhere device link. You’ll need to scan a new pairing code to connect again.")
        }
        .onChange(of: connection.status) { old, new in statusChanged(from: old, to: new) }
        .onChange(of: model.macNotice) { _, _ in showDepartureIfNeeded() }
        .onAppear {
            showDepartureIfNeeded()
            if macName != nil && connection.invitation != nil { onboarding.offerCoach() }
            #if DEBUG
            applyDebugState()
            #endif
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center) {
            FarsideWordmark(size: 28)
            Spacer()
            Menu {
                Button { onboarding.replayCoach() } label: { Label("How to steer", systemImage: "hand.draw") }
                Button { showTroubleshoot = true } label: { Label("Trouble connecting?", systemImage: "questionmark.circle") }
                Button { model.pairingEntry = .paste } label: { Label("Paste Pairing Code", systemImage: "doc.on.clipboard") }
                Button { showDetails = true } label: { Label("Connection Details", systemImage: "network") }
                Button { showPaywall = true } label: { Label("Farside Anywhere", systemImage: "globe") }
                Button { showLegal = true } label: { Label("Third-Party Notices", systemImage: "doc.text") }
                Button { showServerData = true } label: { Label("Server Data", systemImage: "externaldrive") }
                if connection.invitation != nil {
                    Divider()
                    Button(role: .destructive) { confirmForget = true } label: {
                        Label("Forget This Mac", systemImage: "trash")
                    }
                }
            } label: {
                Text("?")
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Help and more")
        }
        .padding(.top, Farside.Space.xs)
    }

    @ViewBuilder private var homeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let macName {
                MacCard(name: macName, status: status, failure: status.tone == .idle ? lastFailure : nil,
                        notice: model.macNotice, lastReached: lastReached)
                connectControl
            } else {
                emptyState
            }
            if !model.error.isEmpty && macName != nil {
                FarsideNotice(message: model.error, tone: .caution)
                    .padding(.top, Farside.Space.m)
            }
            Spacer(minLength: verticalSizeClass == .compact ? Farside.Space.l : Farside.Space.xl)
            if macName != nil { homeList }
            AnywherePlanRow(store: anywhere) { showPaywall = true }
                .padding(.top, Farside.Space.m)
        }
    }

    private func gapArt(fullBleed: Bool) -> some View {
        let busy = status.tone == .busy
        return ReachArt(gap: gapTarget, contact: status.inContact ? 1 : 0,
                        cell: horizontalSizeClass == .regular ? 4.5 : 3.6, active: !covered,
                        ripples: contactRipples, readoutText: busy ? status.text : nil)
            .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.9), value: gapTarget)
            .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.6), value: busy)
            .frame(height: verticalSizeClass == .compact ? 230 : (horizontalSizeClass == .regular ? 250 : 200))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { artSize = $0 }
            .padding(.horizontal, fullBleed ? -20 : 0)
            .overlay(alignment: .bottom) {
                if !busy {
                    Text(gapCaption)
                        .farsideCaption()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Farside.Palette.void)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: status.inContact) { _, contact in
                guard contact, artSize != .zero else { return }
                contactRipples = [HalftoneRipple(center: ReachArt.meetingPoint(in: artSize), date: Date())]
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: status.inContact, condition: { _, contact in contact })
    }

    /// The art's gap follows the connection: reaching the service, the Mac answering, the picture opening.
    private var gapTarget: CGFloat {
        guard macName != nil else { return 64 }
        switch status.progress {
        case 1: return 18
        case 2: return 8
        case 3: return 2
        default: return 34
        }
    }

    private var gapCaption: String {
        macName == nil ? "Gap · nobody paired yet" : "Gap · one tap wide"
    }

    @ViewBuilder private var connectControl: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            if status.needsApproval {
                Label("On your Mac, choose Allow.", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .farsidePlate(Farside.Radius.control, fill: Farside.Palette.panel2, stroke: Farside.Palette.line2)
            }
            if status.tone == .busy {
                Button(action: model.disconnect) {
                    Text("Cancel connection")
                }
                .buttonStyle(FarsideSecondaryButtonStyle(height: 60))
            } else {
                Button(action: connect) { ConnectPillLabel() }
                    .buttonStyle(ConnectPillStyle())
                    .accessibilityLabel("Connect")
                    .accessibilityHint("Closes the gap: opens your Mac’s screen on this iPhone")
                    .accessibilityIdentifier("home.connect")
            }
        }
        .padding(.top, Farside.Space.m)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            FarsideHeading("Your Mac is far. Your reach isn’t.", accent: "isn’t", size: 32)
            Text("Install Farside on your Mac, choose Pair a phone in its menu bar, then scan the code it shows.")
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Farside.Space.xs) {
                Button { model.pairingEntry = .scan } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                .accessibilityLabel("Scan pairing code")
                Button("Paste a pairing code") { model.pairingEntry = .paste }
                    .buttonStyle(FarsideLinkButtonStyle())
            }
            .padding(.top, Farside.Space.xs)
            if !model.error.isEmpty {
                FarsideNotice(message: model.error, tone: .caution)
            }
        }
        .padding(.top, Farside.Space.m)
    }

    private var homeList: some View {
        VStack(spacing: 0) {
            Button { model.pairingEntry = .scan } label: {
                HomeRow(title: "Pair another Mac", trailing: "plus")
            }
            .buttonStyle(.plain)
            Rectangle().fill(Farside.Palette.line).frame(height: 1)
            Button { AgentAlertCenter.shared.showsSettings = true } label: {
                HomeRow(title: "Alerts & Lock Screen", trailing: "bell")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alerts and Lock Screen")
            .accessibilityIdentifier("home.agentAlerts")
            Rectangle().fill(Farside.Palette.line).frame(height: 1)
            Button { onboarding.replayCoach() } label: {
                HomeRow(title: "How to steer · 40 sec", trailing: "arrow.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How to steer, 40 seconds")
        }
        .farsidePlate(Farside.Radius.card, fill: .clear)
    }

    private var lastReached: Date? {
        lastReachedAt > 0 ? Date(timeIntervalSince1970: lastReachedAt) : nil
    }

    // MARK: Behaviour

    private func connect() {
        let access = AnywhereAccess.shared
        guard !access.removalPending, !access.localCleanupPending, !access.removalRecoveryRequired else {
            showServerData = true
            return
        }
        lastFailure = nil
        model.error = ""
        onboarding.beforeConnect {
            Task { @MainActor in
                // Only waits when this phone has Anywhere and its token is due; never more than a few seconds.
                await AnywhereAccess.shared.prepareForConnection()
                guard AnywhereAccess.shared.phoneConnectionAllowed else { showServerData = true; return }
                connection.start()
            }
        }
    }

    /// "Start 7-day free trial" when the person can have one; the paywall shows the full terms first.
    private func primaryTitle(for error: FriendlyError) -> String? {
        guard error.action == .seePlans, let trial = anywhere.offers.lazy.compactMap(\.trialPhrase).first else { return nil }
        return "See the \(trial) free trial"
    }

    private func statusChanged(from old: String, to new: String) {
        if MacStatus(new).tone == .busy { lastFailure = nil }
        guard !connection.isRunning, let name = macName,
              let error = FriendlyError.from(status: new, previous: old, macName: name) else { return }
        let shown = FriendlyError.forLocalOnly(error, serviceAskedForAnywhere: connection.entitlementRequired,
                                               hasPlan: anywhere.entitlement.hasAccess)
        lastFailure = shown
        if !covered || friendlyError != nil { friendlyError = shown }
    }

    private func showDepartureIfNeeded() {
        guard let notice = model.macNotice, notice != shownNotice, !connection.isRunning else { return }
        shownNotice = notice
        guard let presence = MacDeparture(notice: notice) else { return }
        let error = FriendlyError.from(presence: presence.kind, at: presence.time)
        lastFailure = error
        if friendlyError == nil && !covered { friendlyError = error }
    }

    private func resolve(_ error: FriendlyError, action: FriendlyError.Action) {
        friendlyError = nil
        switch action {
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { connect() }
        case .pairAgain:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.pairingEntry = .scan }
        case .seePlans:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showPaywall = true }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func pairingDismissed() {
        guard pairedInSheet else { return }
        pairedInSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onboarding.afterPairing() }
    }

    #if DEBUG
    private func applyDebugState() {
        if LaunchOptions.has("--ui-pairing-scan") { model.pairingEntry = .scan }
        if LaunchOptions.has("--ui-pairing-paste") { model.pairingEntry = .paste }
        if LaunchOptions.has("--ui-troubleshoot") { showTroubleshoot = true }
        if LaunchOptions.has("--ui-paywall") { showPaywall = true }
        if let raw = LaunchOptions.value("--ui-status=") {
            connection.status = raw.replacingOccurrences(of: "_", with: " ")
        } else if LaunchOptions.demoMacName != nil && connection.invitation == nil {
            connection.status = "Ready to connect"
        }
        if LaunchOptions.has("--ui-last-reached") {
            lastReachedAt = Calendar.current.date(bySettingHour: 23, minute: 48, second: 0, of: Date())?.timeIntervalSince1970 ?? 0
        }
        guard let kind = LaunchOptions.value("--ui-error=") else { return }
        let name = macName ?? "MacBook Air"
        let samples: [String: FriendlyError] = [
            "napping": .napping(since: "11:48 PM"), "unreachable": .unreachable(name), "busy": .busy,
            "locked": .locked(since: "11:48 PM"), "needsPlan": .needsPlan, "codeRejected": .codeRejected,
            "declined": .declined, "approvalTimedOut": .approvalTimedOut, "verifyFailed": .verifyFailed,
            "relayUnavailable": .relayUnavailable, "connectionLost": .connectionLost, "sessionGlitch": .sessionGlitch,
            "anywhereUnverified": .anywhereUnverified
        ]
        lastFailure = samples[kind]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { friendlyError = samples[kind] }
    }
    #endif
}

/// The Mac's own account of why it left, parsed from the notice the model wrote.
private struct MacDeparture {
    let kind: HostPresence
    let time: String?

    init?(notice: String) {
        if notice.contains("went to sleep") { kind = .sleeping }
        else if notice.contains("was locked") { kind = .locked }
        else if notice.contains("Another user") { kind = .switchedUser }
        else { return nil }
        time = notice.range(of: #"\d{1,2}[:.]\d{2}(\s?[AaPp]\.?[Mm]\.?)?"#, options: .regularExpression).map { String(notice[$0]) }
    }
}

struct MacStatus: Equatable {
    enum Tone { case idle, busy, caution }
    let text: String
    let tone: Tone
    let needsApproval: Bool
    /// The Mac has answered: the handshake, approval or media setup is under way.
    let inContact: Bool
    /// 0 idle, 1 reaching the service, 2 the Mac answered, 3 opening the picture.
    let progress: Int

    init(_ raw: String) {
        switch raw {
        case "Ready to connect", "Disconnected", "Not connected":
            self.init(text: "Paired · ready when you are", tone: .idle)
        case "Approve this phone on your Mac":
            self.init(text: "Approve this iPhone on your Mac", tone: .busy, needsApproval: true, inContact: true, progress: 2)
        case "new", "checking", "connected", "completed":
            self.init(text: "Opening the picture", tone: .busy, inContact: true, progress: 3)
        case "disconnected", "failed", "closed":
            // Raw media states are transient; the coordinator follows each with a retry or a reason.
            self.init(text: "Reconnecting", tone: .busy, progress: 1)
        default:
            if raw.hasPrefix("Connecting securely") {
                self.init(text: "Connecting securely", tone: .busy, progress: 1)
            } else if raw.hasPrefix("Authenticating") {
                self.init(text: FriendlyError.cardStatus(raw), tone: .busy, inContact: true, progress: 2)
            } else if raw.hasPrefix("Connecting live desktop") {
                self.init(text: FriendlyError.cardStatus(raw), tone: .busy, inContact: true, progress: 3)
            } else if raw.contains("retrying") {
                self.init(text: "Reconnecting", tone: .busy, progress: 1)
            } else if raw.hasPrefix("Pairing removed") || raw.hasPrefix("Pair with your Mac") {
                self.init(text: "Not paired", tone: .idle)
            } else {
                let friendly = FriendlyError.from(status: raw, previous: nil, macName: "Your Mac")
                self.init(text: friendly?.shortStatus ?? raw, tone: .caution)
            }
        }
    }

    private init(text: String, tone: Tone, needsApproval: Bool = false, inContact: Bool = false, progress: Int = 0) {
        self.text = text
        self.tone = tone
        self.needsApproval = needsApproval
        self.inContact = inContact
        self.progress = progress
    }

    var dot: LiveDot.State {
        switch tone {
        case .idle: .idle
        case .busy: inContact ? .live : .busy
        case .caution: .attention
        }
    }
}

/// The saved Mac: name, one honest status line, last reached, and an abstract halftone screen.
struct MacCard: View {
    let name: String
    let status: MacStatus
    var failure: FriendlyError?
    var notice: String?
    var lastReached: Date?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Paired with this iPhone")
                        .font(.subheadline)
                        .foregroundStyle(Farside.Palette.ash)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        LiveDot(state: failure == nil ? status.dot : .attention)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(statusLine)
                            .farsideCaption(Farside.Palette.bone)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Status: \(statusLine)")
                }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    FarsideHalftone(style: HalftoneStyle(cell: 2.5, dotScale: 1.15, dust: 0), animated: false,
                                    scene: FarsideArt.macThumbnail)
                        .frame(width: 104, height: 66)
                        .background(Color.black)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Farside.Palette.line2, lineWidth: 1))
                }
            }
            Rectangle().fill(Farside.Palette.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text(lastReachedText).farsideCaption()
                Spacer(minLength: 8)
                if lastReached != nil { Text("We won’t ask why").farsideCaption() }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(18)
        .farsidePlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.mac")
    }

    private var statusLine: String {
        if let failure, status.tone != .busy { return failure.shortStatus }
        return status.text
    }

    private var lastReachedText: String {
        guard let lastReached else { return "Not reached yet" }
        let time = lastReached.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(lastReached) { return "Last reached \(time)" }
        if Calendar.current.isDateInYesterday(lastReached) { return "Last reached yesterday \(time)" }
        return "Last reached \(lastReached.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

/// "Connect · Closes the gap" with the ember arrow in an ink circle.
private struct ConnectPillLabel: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Farside.Palette.ink)
                Text("Closes the gap")
                    .farsideCaption(Farside.Palette.inkMuted)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Farside.Palette.ember)
                .frame(width: 60, height: 60)
                .background(Farside.Palette.ink, in: .circle)
        }
        .padding(.leading, 28)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, minHeight: 78)
    }
}

private struct ConnectPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Farside.Palette.bone.opacity(configuration.isPressed ? 0.85 : 1), in: .capsule)
            .shadow(color: Farside.Palette.bone.opacity(0.16), radius: 24)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: configuration.isPressed)
    }
}

private struct HomeRow: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Farside.Palette.bone)
            Spacer()
            Image(systemName: trailing)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.ash)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .contentShape(.rect)
    }
}

private struct ConnectionDetailsSheet: View {
    @ObservedObject var connection: RemoteCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(connection.diagnostics)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Farside.Palette.bone)
                        .textSelection(.enabled)
                        .listRowBackground(Farside.Palette.panel)
                } header: {
                    Text("Route").farsideCaption()
                }
                Section {
                    Text(connection.inputSummary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Farside.Palette.bone)
                        .textSelection(.enabled)
                        .listRowBackground(Farside.Palette.panel)
                } header: {
                    Text("Input").farsideCaption()
                }
                if let proof = connection.localProofSummary {
                    Section {
                        Text(proof)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Farside.Palette.bone)
                            .textSelection(.enabled)
                            .listRowBackground(Farside.Palette.panel)
                            .accessibilityIdentifier("remote.localProofSummary")
                    } header: {
                        Text("Local link proof").farsideCaption()
                    }
                }
                Section {
                    Toggle("Relay-only test", isOn: Binding(get: { connection.forceRelay },
                                                              set: { connection.forceRelay = $0 }))
                        .toggleStyle(FarsideSwitchStyle())
                        .disabled(connection.connected)
                        .listRowBackground(Farside.Palette.panel)
                } footer: {
                    Text("For testing the relay route. Leave off for normal use.")
                        .foregroundStyle(Farside.Palette.ash)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Farside.Palette.void2)
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Farside.Palette.bone)
        .presentationDetents([.medium, .large])
        .farsideSheet()
    }
}

/// What the screen shows after Farside returns from the background: hidden, reconnecting or ended.
struct ConcealedRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Presentation { case hidden, reconnecting, reconnectFailed, ended }

    private var presentation: Presentation {
        switch model.resumeState {
        case .backgrounded: return .hidden
        case .reconnecting:
            return connection.connected || MacStatus(connection.status).tone == .busy ? .reconnecting : .reconnectFailed
        case .none, .needsChoice: return .ended
        }
    }

    private var canReconnect: Bool { connection.invitation != nil && !LaunchOptions.layoutCheck }
    private var macName: String { connection.invitation?.name ?? "your Mac" }

    private var title: String {
        switch presentation {
        case .hidden: "Screen hidden"
        case .reconnecting: "Reconnecting…"
        case .reconnectFailed: "Could not reconnect"
        case .ended: "Session ended"
        }
    }

    private var message: String {
        switch presentation {
        case .hidden: "Farside hides your Mac’s screen while it’s in the background."
        case .reconnecting: "Resuming your session with \(macName). Your pairing is kept."
        case .reconnectFailed: model.macNotice ?? MacStatus(connection.status).text
        case .ended: "Farside hid your Mac’s screen while it was in the background. Reconnect to continue."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04),
                            scene: presentation == .reconnecting ? FarsideArt.reach(gap: 10, contact: 0.6) : FarsideArt.hidden)
                .frame(height: verticalSizeClass == .compact ? 120 : 240)
                .padding(.horizontal, -Farside.Space.l)
            FarsideHeading(title, size: 34)
                .padding(.top, Farside.Space.xs)
            Text(message)
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Farside.Space.s)
            Spacer(minLength: Farside.Space.l)
            VStack(spacing: Farside.Space.xs) {
                switch presentation {
                case .hidden:
                    EmptyView()
                case .reconnecting:
                    Button(action: model.dismissConcealment) {
                        Text("Cancel")
                    }
                    .buttonStyle(FarsideSecondaryButtonStyle())
                case .reconnectFailed, .ended:
                    if canReconnect {
                        Button(action: model.reconnect) {
                            Text("Reconnect")
                        }
                        .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                    }
                    Button(action: model.dismissConcealment) {
                        Text("Return to Farside")
                    }
                    .buttonStyle(FarsideSecondaryButtonStyle())
                }
            }
        }
        .padding(Farside.Space.l)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FarsideBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.concealed")
    }
}
