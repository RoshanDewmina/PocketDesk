import SwiftUI

struct PhoneRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @StateObject private var onboarding = OnboardingFlow()
    /// A live session stays on screen while it reconnects by itself, so zoom and pan survive a blip.
    @State private var sessionHeld = false
    /// `showsSession`, changed inside an animation so the session opens and closes with D38's motion.
    @State private var presentedSession = false
    @State private var irisAnchor = UnitPoint(x: 0.52, y: 0.25)
    @State private var returningFromSession = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsSession: Bool {
        (connection.connected || connection.remoteVideo != nil
            || (sessionHeld && MacStatus(connection.status).tone == .busy))
            && (presentedSession || !OnboardingFlow.first60Enabled() || model.firstPictureReady)
    }

    var body: some View {
        // Home is the first branch so the session, inserted or removed over it, draws on top.
        Group {
            if !presentedSession && !model.contentConcealed && !LaunchOptions.layoutCheck {
                HomeView(model: model, connection: connection, onboarding: onboarding)
                    .environment(\.farsideReturningFromSession, returningFromSession)
                    .transition(.opacity)
            } else if presentedSession {
                // A held background session keeps its viewport; the overlay hides every remote pixel.
                NativeSessionView(model: model, connection: connection, offlineLayoutCheck: false,
                                  replayCoach: onboarding.replayCoach)
                    .overlay {
                        if model.contentConcealed { ConcealedRemoteView(model: model, connection: connection) }
                    }
                    .transition(.farsideSession(anchor: irisAnchor, reduceMotion: reduceMotion))
                    .zIndex(1)
            } else if model.contentConcealed {
                ConcealedRemoteView(model: model, connection: connection)
            } else {
                NativeSessionView(model: model, connection: connection, offlineLayoutCheck: true,
                                  replayCoach: onboarding.replayCoach)
            }
        }
        .overlay(alignment: .bottom) {
            if !presentedSession && !model.contentConcealed && !LaunchOptions.layoutCheck, let warning = model.dataWarning {
                // On Home the card sits at the bottom; a session shows it under its top pills instead,
                // clear of the dock and End session.
                DataWarningCard(content: warning, useLessData: model.useLessData, keep: model.keepDataQuality)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        // Read once per change of Home's art, never on keyboard or rotation frames of the session.
        .onPreferenceChange(ReachMeetingPointKey.self) { point in
            guard let point, let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size,
                  screen.width > 0, screen.height > 0 else { return }
            irisAnchor = UnitPoint(x: point.x / screen.width, y: point.y / screen.height)
        }
        .onAppear { presentedSession = showsSession }
        .onChange(of: showsSession) { was, now in
            if was && !now {
                returningFromSession = true
                if model.sessionEndReason == .user { ConnectHaptics.shared.play(.softEnd) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { returningFromSession = false }
            }
            withAnimation(.farsideSession(reduceMotion: reduceMotion)) { presentedSession = now }
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
        .onReceive(model.usefulSession.$evidence) { evidence in
            if evidence.ready(at: ProcessInfo.processInfo.systemUptime) { onboarding.offerCoach() }
        }
        .onChange(of: connection.connected) { _, connected in
            if connected {
                // Finger meets pointer (D38). A held session coming back gets its own "back" beat.
                if !sessionHeld { ConnectHaptics.shared.play(.meet) }
                LastReached.record(Date(), room: connection.invitation?.room)
                sessionHeld = true
            }
        }
        .onChange(of: connection.status) { _, status in
            if !connection.connected && MacStatus(status).tone != .busy { sessionHeld = false }
        }
        .modifier(E2EStateProbeModifier())
        #if DEBUG
        .modifier(SimulatedSessionWindow())
        #endif
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
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @ObservedObject var onboarding: OnboardingFlow
    @State private var showDetails = false
    @State private var showTroubleshoot = false
    @State private var confirmForget = false
    @State private var friendlyError: FriendlyError?
    @State private var lastFailure: FriendlyError?
    @State private var attemptRoute: PhoneRecovery.Route = .unknown
    /// The result of "Check again": a reachability check that opens no session.
    @State private var checkedHealth: ConnectionHealth?
    @State private var checking = false
    @State private var shownNotice: String?
    @State private var pairedInSheet = false
    @State private var contactRipples: [HalftoneRipple] = []
    @State private var artSize: CGSize = .zero
    @State private var regularIntroHeight: CGFloat = 302
    /// When the current connect started waiting; drives the "still trying" rings (D38).
    @State private var searchStart: Date?
    /// The art's reaction to a known failure, shown briefly before the error cover.
    @State private var failurePose: FriendlyError.Kind?
    /// Set once when a session has just ended, so the hand eases back from the pointer.
    @State private var retreatGap: CGFloat?
    @Environment(\.farsideReturningFromSession) private var returning
    @State private var showPaywall = false
    @State private var showServerData = false
    @State private var showLegal = false
    @State private var showSecurity = false
    @State private var showPairedMacs = false
    @State private var savedMacs: [PairedMac] = []
    @AppStorage(OnboardingFlow.firstPictureKey) private var firstPictureShown = false
    private var showsLaterOptions: Bool {
        if !OnboardingFlow.first60Enabled() || firstPictureShown { return true }
        #if DEBUG
        // Existing screenshot/layout fixtures describe an established user.
        if !LaunchOptions.has("--ui-first60"), LaunchOptions.has("--ui-demo-mac") { return true }
        #endif
        return false
    }
    @State private var lastBattery: MacVitalsMemory.LastSeen?
    @ObservedObject private var anywhere = AnywhereStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastReached: Date?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var macName: String? { connection.invitation?.name ?? LaunchOptions.demoMacName }
    private var savedMacState: SavedMacHomeState { SavedMacHomeState(selected: connection.invitation, saved: savedMacs) }
    private func refreshSavedMacs() { savedMacs = PairedMacs.all() }
    private var status: MacStatus { MacStatus(connection.status, couch: model.attemptMode == .couch) }
    private var covered: Bool { model.pairingEntry != nil || friendlyError != nil || onboarding.step != nil || showDetails || showTroubleshoot || showPaywall || showServerData || showLegal || showSecurity || showPairedMacs }

    var body: some View {
        GeometryReader { proxy in
            if FarsideShellLayout.twoColumns(horizontal: horizontalSizeClass, typeSize: typeSize,
                                            enabled: FarsideShellLayout.enabled) {
                regularHome(windowWidth: proxy.size.width)
            } else if verticalSizeClass == .compact && !(horizontalSizeClass == .regular && typeSize.isAccessibilitySize && FarsideShellLayout.enabled) {
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
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            guard let sizeClass else { return }
            ViewportPreference.initialize(regularWidth: sizeClass == .regular)
        }
        .sheet(item: $model.pairingEntry, onDismiss: pairingDismissed) { entry in
            PairingSheet(model: model, entry: entry, replacing: connection.invitation?.name) { pairedInSheet = true }
        }
        .sheet(isPresented: $showDetails) {
            ConnectionDetailsSheet(model: model, connection: connection, health: health)
        }
        .sheet(isPresented: $showTroubleshoot) {
            TroubleshootSheet(macName: macName ?? "Your Mac", route: attemptRoute,
                              failure: PhoneRecovery.Failure(lastFailure), retry: { connect(mode: model.attemptMode) })
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
        .sheet(isPresented: $showLegal) { LegalNoticesView().farsideRegularSheet() }
        .sheet(isPresented: $showSecurity) { SecuritySettingsSheet() }
        .sheet(isPresented: $showPairedMacs) { PairedMacSelectionSheet(model: model).farsideSheet() }
        .sheet(isPresented: $showServerData) {
            ServerDataRemovalView(connection: connection, access: AnywhereAccess.shared).farsideSheet()
        }
        .confirmationDialog("Forget this Mac locally?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive, action: forgetMac)
        } message: {
            Text("This removes local pairing only. Server Data removes your Anywhere device link. You’ll need to scan a new pairing code to connect again.")
        }
        .onChange(of: connection.status) { old, new in statusChanged(from: old, to: new) }
        .onChange(of: connection.serviceAccess) { _, access in
            // stop() clears access; preserve the failed attempt for recovery instead of replacing it.
            if let access {
                attemptRoute = PhoneRecovery.route(localOnly: connection.localOnly, couch: model.attemptMode == .couch,
                                                   serviceAccess: access, hasPlan: anywhere.entitlement.hasAccess)
            }
        }
        .onChange(of: model.macNotice) { _, _ in showDepartureIfNeeded() }
        .onChange(of: model.couchRefusal) { _, _ in showCouchRefusalIfNeeded() }
        .onAppear {
            refreshSavedMacs()
            refreshLastReached()
            attemptRoute = PhoneRecovery.route(localOnly: connection.localOnly, couch: model.attemptMode == .couch,
                                               serviceAccess: connection.serviceAccess, hasPlan: anywhere.entitlement.hasAccess)
            showDepartureIfNeeded()
            showCouchRefusalIfNeeded()
            if macName != nil && connection.invitation != nil { onboarding.offerCoach() }
            #if DEBUG
            applyDebugState()
            #endif
            refreshLastBattery()
        }
        .onChange(of: connection.invitation) { _, _ in
            refreshSavedMacs()
            refreshLastReached()
            checkedHealth = nil
            lastFailure = nil
            attemptRoute = .unknown
            lastBattery = nil
            model.refreshSendToMac(force: true)
        }
        .onChange(of: connection.connected) { _, _ in refreshLastBattery(); refreshLastReached() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshSavedMacs(); refreshLastBattery(); refreshLastReached() } }
    }

    private func refreshLastBattery() {
        lastBattery = connection.connected ? nil : model.vitalsMemory.lastSeen(room: connection.invitation?.room, now: Date())
    }

    private func refreshLastReached() {
        LastReached.adoptLegacy(room: connection.invitation?.room)
        lastReached = LastReached.date(room: connection.invitation?.room)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center) {
            FarsideWordmark(size: 28)
            Spacer()
            Menu {
                Button { showPairedMacs = true } label: { Label("Your Macs", systemImage: "laptopcomputer") }
                Button { onboarding.replayCoach() } label: { Label("How to steer", systemImage: "hand.draw") }
                Button { showTroubleshoot = true } label: { Label("Trouble connecting?", systemImage: "questionmark.circle") }
                Button { model.pairingEntry = .paste } label: { Label("Paste Pairing Code", systemImage: "doc.on.clipboard") }
                Button { showDetails = true } label: { Label("Connection Details", systemImage: "network") }
                Button { showPaywall = true } label: { Label("Farside Anywhere", systemImage: "globe") }
                if !showsLaterOptions, connection.invitation != nil {
                    Button(CouchCopy.entryTitle) { connect(mode: .couch) }
                    Toggle("Local network only", isOn: Binding(get: { connection.localOnly }, set: { model.setLocalOnly($0) }))
                        .disabled(!connection.localOnly && connection.invitation?.hasOwnerLocalIdentity != true)
                    Button("Alerts & Lock Screen") { AgentAlertCenter.shared.showsSettings = true }
                }
                Button { showLegal = true } label: { Label("Third-Party Notices", systemImage: "doc.text") }
                Button { showServerData = true } label: { Label("Server Data", systemImage: "externaldrive") }
                Button { showSecurity = true } label: { Label("Settings", systemImage: "gearshape") }
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

    private func regularHome(windowWidth: CGFloat) -> some View {
        let columns = FarsideShellLayout.columns(windowWidth: windowWidth)
        return HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        gapArt(fullBleed: false)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { regularIntroHeight = $0 }
                    homePrimary
                }
                .padding(.bottom, Farside.Space.m)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: columns.leading)
            .accessibilityIdentifier("home.leading")
            ScrollView {
                if macName != nil || savedMacState == .choose {
                    homeUtilities
                        .padding(.top, regularIntroHeight)
                        .padding(.bottom, Farside.Space.m)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: columns.trailing)
            .accessibilityIdentifier("home.trailing")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("phone.home")
    }

    private var homeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            homePrimary
            Spacer(minLength: verticalSizeClass == .compact ? Farside.Space.l : Farside.Space.xl)
            homeUtilities
        }
    }

    @ViewBuilder private var homePrimary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let macName {
                MacCard(name: macName, status: status, health: health, checking: checking,
                        notice: model.macNotice, lastReached: lastReached,
                        vitalsNote: lastBattery.map(MacVitalsMemory.homeNote),
                        vitalsCause: model.lastDeparture == .sleeping ? lastBattery.map(MacVitalsMemory.sleepNote) : nil,
                        act: act)
                connectControl
            } else if savedMacState == .choose {
                VStack(alignment: .leading, spacing: Farside.Space.s) {
                    FarsideHeading("Choose your Mac.", accent: "your", size: 30)
                    Text("Your other Macs are still saved. Choose one before connecting.")
                        .foregroundStyle(Farside.Palette.ash).fixedSize(horizontal: false, vertical: true)
                    Button { showPairedMacs = true } label: { Label("Choose a Mac", systemImage: "laptopcomputer") }
                        .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                        .accessibilityIdentifier("home.chooseSavedMac")
                }.padding(.top, Farside.Space.m)
            } else {
                emptyState
            }
            if !model.error.isEmpty && macName != nil {
                FarsideNotice(message: model.error, tone: .caution)
                    .padding(.top, Farside.Space.m)
            }
        }
    }

    private var homeUtilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLaterOptions {
                if macName != nil || savedMacState == .choose { homeList }
                AnywherePlanRow(store: anywhere) { showPaywall = true }
                    .padding(.top, Farside.Space.m)
            }
        }
    }

    private func gapArt(fullBleed: Bool) -> some View {
        let busy = status.tone == .busy
        let gap = retreatGap ?? gapTarget
        let rings = busy && !reduceMotion ? ReachArt.searchRings(from: searchStart, in: artSize, gap: gapTarget) : []
        return ReachArt(gap: gap, contact: status.inContact ? 1 : 0,
                        cell: horizontalSizeClass == .regular ? 4.5 : 3.6, active: !covered,
                        ripples: contactRipples + rings, readoutStage: busy ? ConnectStage(progress: status.progress) : nil,
                        sink: failurePose == .napping ? 1 : 0, fade: failurePose == .unreachable ? 1 : 0)
            .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.9), value: gapTarget)
            .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.6), value: busy)
            .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.8), value: failurePose)
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    let meet = ReachArt.meetingPoint(in: frame.size)
                    Color.clear.preference(key: ReachMeetingPointKey.self,
                                           value: CGPoint(x: frame.minX + meet.x, y: frame.minY + meet.y))
                }
            }
            .onChange(of: busy) { _, nowBusy in
                searchStart = nowBusy ? Date() : nil
                if nowBusy { failurePose = nil }
            }
            .onChange(of: status.progress) { old, new in
                if new == 3 && old < 3 { ConnectHaptics.shared.play(.click) }
            }
            .onAppear {
                guard returning, !reduceMotion else { return }
                retreatGap = 2
                DispatchQueue.main.async { withAnimation(Farside.Motion.easeOut(0.9)) { retreatGap = nil } }
            }
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
                ConnectHaptics.shared.play(.contact)
            }
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
                Button { connect() } label: { ConnectPillLabel() }
                    .buttonStyle(ConnectPillStyle())
                    .disabled(checking)
                    .accessibilityLabel("Connect")
                    .accessibilityHint("Closes the gap: opens your Mac’s screen on this \(DeviceWord.current)")
                    .accessibilityIdentifier("home.connect")
                if showsLaterOptions {
                VStack(spacing: 6) {
                    Button(CouchCopy.entryTitle) { connect(mode: .couch) }
                        .buttonStyle(FarsideSecondaryButtonStyle(height: 52))
                        .accessibilityIdentifier("home.couch")
                    // The caption style uppercases; the label keeps the sentence as written.
                    Text(CouchCopy.entryCaption)
                        .farsideCaption()
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(CouchCopy.entryCaption)
                }
                .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, Farside.Space.m)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            FarsideHeading("Your Mac is far. Your reach isn’t.", accent: "isn’t", size: 32)
            Text(OnboardingFlow.first60Enabled()
                 ? "Farside needs its free Mac helper. Send yourself the link, open it on your Mac, then scan the code it shows."
                 : "Install Farside on your Mac, choose Pair a phone in its menu bar, then scan the code it shows.")
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Farside.Space.xs) {
                if OnboardingFlow.first60Enabled() {
                    ShareLink(item: URL(string: "https://getfarside.com/mac")!) {
                        Label("Get Farside for Mac", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                    .accessibilityIdentifier("home.getMac")
                    Text("getfarside.com/mac")
                        .font(.footnote).foregroundStyle(Farside.Palette.ash)
                }
                Button { model.pairingEntry = .scan } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(FarsideSecondaryButtonStyle(height: 60))
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
            Button { showPairedMacs = true } label: {
                HomeRow(title: "Your Macs", trailing: "laptopcomputer")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.pairedMacs")
            Rectangle().fill(Farside.Palette.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Local network only", isOn: Binding(get: { connection.localOnly }, set: { model.setLocalOnly($0) }))
                .accessibilityIdentifier("home.localOnly")
                .disabled(!connection.localOnly && connection.invitation?.hasOwnerLocalIdentity != true)
                Text(connection.invitation == nil
                     ? "Choose a saved Mac first. Enable Local network only on both devices."
                     : connection.invitation?.hasOwnerLocalIdentity == true
                        ? "Enable this on your Mac too. Connection requires a verified local route."
                        : "Re-pair from a fresh owner-approved QR code on this Mac to enable Local network only. Connect normally until then.")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Farside.Palette.line).frame(height: 1)
            if connection.invitation?.ownerPairID == nil, connection.invitation != nil {
                Text("Send to My Mac needs a fresh owner-approved pairing. Confirm the new pairing works before forgetting its older record.")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash).padding(16)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// Connection Health for the card: the newest check, else what the last attempt ended with.
    private var health: ConnectionHealth? {
        guard status.tone != .busy else { return nil }
        return checkedHealth ?? lastFailure.map(ConnectionHealth.after)
    }

    // MARK: Behaviour

    private func act(_ action: ConnectionHealth.Action) {
        switch action {
        case .checkAgain: checkReachability()
        case .seePlans: showPaywall = true
        case .pairAgain: model.pairingEntry = .scan
        case .retry: connect()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .wakeDisplay, .none: break
        }
    }

    /// Asks the service whether the Mac's Farside is answering. It opens no session and sends nothing to
    /// the Mac, so Connect waits until it finishes (the service allows one phone per room).
    private func checkReachability() {
        guard !connection.localOnly else {
            model.error = "Connect using Local network only to check your Mac on this network."
            return
        }
        guard let invitation = connection.invitation, !checking, !connection.isRunning, !connection.connected else { return }
        checking = true
        Task { @MainActor in
            let outcome = await MacReachabilityProbe().check(invitation)
            checking = false
            guard connection.invitation == invitation, !connection.localOnly,
                  !connection.isRunning, !connection.connected else { return }
            MacWidgetSync.shared.update(macName: invitation.name, room: invitation.room, observed: MacWidgetSync.presence(for: outcome))
            checkedHealth = .checked(outcome, lastReached: lastReached.map { LastReached.spoken($0) })
        }
    }

    private func connect(mode: SessionMode = .picture) {
        guard !checking else { return }
        attemptRoute = PhoneRecovery.route(localOnly: connection.localOnly, couch: mode == .couch,
                                           serviceAccess: nil, hasPlan: anywhere.entitlement.hasAccess)
        let decision = ConnectGate.connect(model: model, onboarding: onboarding, restartsRunning: true, mode: mode) {
            showServerData = true
        }
        if decision == .proceed {
            lastFailure = nil
            checkedHealth = nil
            failurePose = nil
            ConnectHaptics.shared.play(.press)
        }
    }

    /// With Settings → Security on, the owner confirms first; a refusal leaves the pairing as it was.
    private func forgetMac() {
        Task { @MainActor in
            let intendedInvitation = connection.invitation
            let gate = DeviceOwnerGate.live
            let outcome = await gate.check(.forgetMac)
            guard outcome.allows else {
                model.error = DeviceOwnerGate.message(for: outcome, purpose: .forgetMac,
                                                      biometryName: gate.authenticator.biometryName) ?? ""
                return
            }
            guard let intendedInvitation, connection.invitation == intendedInvitation else {
                model.error = "Selected Mac changed. Choose the Mac to forget again."
                return
            }
            let room = intendedInvitation.room
            let bigTextHost = connection.presentationHostTrust
            model.disconnect()
            guard connection.revoke(expectedInvitation: intendedInvitation) else { return }
            if let bigTextHost { model.bigTextMemory.forget(host: bigTextHost) }
            else { model.bigTextMemory.forget(room: room) }
            model.refreshSendToMac(force: true)
            model.vitalsMemory.forget(room: room)
            refreshLastBattery()
            LastReached.forget(room: room)
            lastReached = nil
            lastFailure = nil
            checkedHealth = nil
        }
    }

    /// "Start 7-day free trial" when the person can have one; the paywall shows the full terms first.
    private func primaryTitle(for error: FriendlyError) -> String? {
        guard error.action == .seePlans, let trial = anywhere.offers.lazy.compactMap(\.trialPhrase).first else { return nil }
        return "See the \(trial) free trial"
    }

    private func statusChanged(from old: String, to new: String) {
        if MacStatus(new).tone == .busy {
            lastFailure = nil; checkedHealth = nil
            // Siri, widgets and recovery can start through ConnectGate without Home.connect().
            attemptRoute = PhoneRecovery.route(localOnly: connection.localOnly, couch: model.attemptMode == .couch,
                                               serviceAccess: connection.serviceAccess, hasPlan: anywhere.entitlement.hasAccess)
        }
        guard !connection.isRunning else { return }
        if let couch = FriendlyError.forCouch(status: new, requestedCouch: model.attemptMode == .couch) {
            lastFailure = couch
            if !covered || friendlyError != nil { friendlyError = couch }
            return
        }
        guard let name = macName,
              let error = FriendlyError.from(status: new, previous: old, macName: name) else { return }
        let localError = FriendlyError.forLocalOnly(error, serviceAskedForAnywhere: connection.entitlementRequired,
                                               hasPlan: anywhere.entitlement.hasAccess)
        let shown = PhoneRecovery.error(localError, route: attemptRoute, enabled: PhoneRecovery.enabled)
        lastFailure = shown
        checkedHealth = nil
        guard !covered || friendlyError != nil else { return }
        // Let the art react to the known reason first (the pointer naps or dissolves), then explain it.
        let pose: FriendlyError.Kind? = shown.kind == .napping || shown.kind == .unreachable ? shown.kind : nil
        guard let pose, !reduceMotion, friendlyError == nil else { friendlyError = shown; return }
        failurePose = pose
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if lastFailure == shown && friendlyError == nil { friendlyError = shown }
        }
    }

    private func showDepartureIfNeeded() {
        guard let notice = model.macNotice, notice != shownNotice, !connection.isRunning else { return }
        shownNotice = notice
        guard let presence = MacDeparture(notice: notice) else { return }
        let error = FriendlyError.from(presence: presence.kind, at: presence.time)
        lastFailure = error
        checkedHealth = nil
        if friendlyError == nil && !covered { friendlyError = error }
    }

    /// The Mac refused Couch mode; the model already ended that attempt.
    private func showCouchRefusalIfNeeded() {
        guard let reason = model.couchRefusal else { return }
        model.clearCouchRefusal()
        let error = FriendlyError.couch(reason)
        lastFailure = error
        if !covered || friendlyError != nil { friendlyError = error }
    }

    private func resolve(_ error: FriendlyError, action: FriendlyError.Action) {
        friendlyError = nil
        switch action {
        case .retry:
            let mode = model.attemptMode
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { connect(mode: mode) }
        case .connectWithPicture:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { connect(mode: .picture) }
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
        if LaunchOptions.has("--ui-troubleshoot-anywhere") { attemptRoute = .anywhere; showTroubleshoot = true }
        if LaunchOptions.has("--ui-troubleshoot-local") { attemptRoute = .localNetwork; showTroubleshoot = true }
        if LaunchOptions.has("--ui-paywall") { showPaywall = true }
        if let raw = LaunchOptions.value("--ui-status=") {
            connection.status = raw.replacingOccurrences(of: "_", with: " ")
        } else if LaunchOptions.demoMacName != nil && connection.invitation == nil {
            connection.status = "Ready to connect"
        }
        if LaunchOptions.has("--ui-last-reached") {
            lastReached = Calendar.current.date(bySettingHour: 23, minute: 48, second: 0, of: Date())
        }
        guard let kind = LaunchOptions.value("--ui-error=") else { return }
        let name = macName ?? "MacBook Air"
        let samples: [String: FriendlyError] = [
            "napping": .napping(since: "11:48 PM"), "unreachable": .unreachable(name), "busy": .busy,
            "locked": .locked(since: "11:48 PM"), "needsPlan": .needsPlan, "codeRejected": .codeRejected,
            "declined": .declined, "approvalTimedOut": .approvalTimedOut, "verifyFailed": .verifyFailed,
            "relayUnavailable": .relayUnavailable, "connectionLost": .connectionLost, "sessionGlitch": .sessionGlitch,
            "anywhereUnverified": .anywhereUnverified, "couchNotLocal": .couch(.notLocal),
            "couchControlOff": .couch(.controlOff)
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

    init(_ raw: String, couch: Bool = false) {
        if couch && raw.hasPrefix("Connecting live desktop") {
            self.init(text: CouchCopy.checking, tone: .busy, inContact: true, progress: 3)
        } else {
            self.init(raw: raw, couch: couch)
        }
    }

    private init(raw: String, couch: Bool) {
        switch raw {
        case "Ready to connect", "Disconnected", "Not connected":
            self.init(text: "Paired · ready when you are", tone: .idle)
        case "Approve this phone on your Mac":
            self.init(text: "Approve this \(DeviceWord.current) on your Mac", tone: .busy, needsApproval: true, inContact: true, progress: 2)
        case "new", "checking", "connected", "completed":
            self.init(text: "Opening the picture", tone: .busy, inContact: true, progress: 3)
        case "disconnected", "failed", "closed":
            // Raw media states are transient; the coordinator follows each with a retry or a reason.
            self.init(text: "Reconnecting", tone: .busy, progress: 1)
        default:
            if raw == First60PermissionWait(stage: .screenRecording).message {
                self.init(text: "Waiting for your Mac to share its screen", tone: .busy, inContact: true, progress: 3)
            } else if raw == First60PermissionWait(stage: .accessibility).message {
                self.init(text: "Allow control on your Mac", tone: .busy, inContact: true, progress: 3)
            } else if raw.hasPrefix("Connecting securely") {
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
                    ?? FriendlyError.forCouch(status: raw, requestedCouch: couch)
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
    /// What went wrong and the one next step; nil while connecting or when nothing is wrong.
    var health: ConnectionHealth?
    var checking = false
    var notice: String?
    var lastReached: Date?
    var vitalsNote: String?
    var vitalsCause: String?
    var act: (ConnectionHealth.Action) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Paired with this \(DeviceWord.current)")
                        .font(.subheadline)
                        .foregroundStyle(Farside.Palette.ash)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        LiveDot(state: dotState)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(statusLine)
                            .farsideCaption(Farside.Palette.bone)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Status: \(statusLine)")
                    if let health, status.tone != .busy {
                        Text(health.nextStep)
                            .font(.footnote)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 16)
                            .accessibilityLabel("Next step: \(health.nextStep)")
                            .accessibilityIdentifier("home.health.next")
                        if let title = cardActionTitle(health.action) {
                            Button(checking ? "Checking…" : title) { act(health.action) }
                                .buttonStyle(FarsideLinkButtonStyle())
                                .disabled(checking)
                                .padding(.leading, 16)
                                .accessibilityIdentifier("home.health.action")
                        }
                    }
                    if let vitalsNote {
                        Text(vitalsNote)
                            .font(.footnote)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                            .padding(.leading, 16)
                            .accessibilityIdentifier("home.vitals")
                    }
                    if let vitalsCause {
                        Text(vitalsCause)
                            .font(.footnote)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 16)
                            .accessibilityIdentifier("home.vitals.cause")
                    }
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
        if let health, status.tone != .busy { return health.title }
        return status.text
    }

    private var dotState: LiveDot.State {
        guard let health, status.tone != .busy else { return status.dot }
        return health.state == .macAnswering ? .idle : .attention
    }

    /// Connect below the card already retries, so the card offers only the other next actions.
    private func cardActionTitle(_ action: ConnectionHealth.Action) -> String? {
        switch action {
        case .checkAgain, .seePlans, .pairAgain, .openSettings: action.title
        case .retry, .wakeDisplay, .none: nil
        }
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
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    var health: ConnectionHealth?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let health {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(health.title).foregroundStyle(Farside.Palette.bone)
                            Text("\(health.detail) \(health.nextStep)")
                                .font(.footnote)
                                .foregroundStyle(Farside.Palette.ash)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Farside.Palette.panel)
                    } header: {
                        Text("Health").farsideCaption()
                    }
                }
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
                    DiagnosticReportRows(model: model)
                        .listRowBackground(Farside.Palette.panel)
                } header: {
                    Text("Test My Mac and session reports").farsideCaption()
                }
                #if DEBUG
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
                #endif
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
        .farsideCompactDetents([.medium, .large])
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
