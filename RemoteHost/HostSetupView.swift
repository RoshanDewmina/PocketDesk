import SwiftUI

/// The setup window: a halftone rail with the four steps on the left, the current step on the
/// right. The model decides how far setup may go; Back and Continue move within that.
struct HostSetupView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var page: HostSetupPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: HostViewState, actions: HostActions, page: HostSetupPage? = nil) {
        self.state = state
        self.actions = actions
        _page = State(initialValue: page ?? HostSetupFlow.initialPage(for: state))
    }

    var body: some View {
        HStack(spacing: 0) {
            HostSetupRail(page: page, state: state)
                .frame(width: HostTheme.railWidth)
            VStack(alignment: .leading, spacing: 0) {
                HostDotProgress(page: page,
                                filled: HostSetupFlow.progressDots(page: page, state: state),
                                caption: HostSetupFlow.progressCaption(page: page, state: state))
                    .padding(.bottom, 22)
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(page)
                    .transition(.opacity)
                footer
                    .padding(.top, 12)
            }
            .padding(.top, 28)
            .padding(.horizontal, 30)
            .padding(.bottom, 22)
        }
        .frame(width: HostTheme.setupSize.width, height: HostTheme.setupSize.height)
        .background(HostTheme.windowBackground)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : Farside.Motion.easeOut(), value: page)
        .onChange(of: state.setupStep) { old, new in
            page = HostSetupFlow.page(afterStepChangeFrom: old, to: new, current: page)
        }
        .onChange(of: state.pairingDeferred) { _, deferred in
            // Skip moves on to the ready check; Pair there (or in the menu bar) comes back.
            if deferred && page == .pair { page = .ready }
            if !deferred && page == .ready && state.setupStep == .pairPhone { page = .pair }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .hello: HostHelloPage()
        case .permissions: HostPermissionsPage(state: state, actions: actions)
        case .pair: HostPairingPage(state: state, actions: actions)
        case .ready: HostReadyPage(state: state, actions: actions)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(page == .ready
                 ? "Stay on, awake and logged in. After a restart, log in once."
                 : "We only look while a phone you approved is connected.")
                .font(.system(size: 12.5))
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if let previous = HostSetupPage(rawValue: page.rawValue - 1) {
                Button("Back") { page = previous }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 34))
                    .accessibilityIdentifier("farside.setup.back")
            }
            if page == .ready {
                Button("Done", action: actions.finishSetup)
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 34))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.setup.done")
            } else {
                let enabled = HostSetupFlow.canContinue(from: page, state: state)
                Button("Continue") {
                    guard let next = HostSetupPage(rawValue: page.rawValue + 1) else { return }
                    page = min(next, HostSetupFlow.furthestPage(for: state.setupStep,
                                                                pairingDeferred: state.pairingDeferred))
                }
                .buttonStyle(HostButtonStyle(kind: enabled ? .primary : .plate, height: 34))
                .disabled(!enabled)
                .hostDefaultAction(enabled)
                .accessibilityIdentifier("farside.setup.continue")
            }
        }
    }
}

// MARK: Rail and progress

struct HostSetupRail: View {
    let page: HostSetupPage
    let state: HostViewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scene = HostArtScene.setupRail(reach: page.rawValue,
                                           contact: page == .ready && state.status.isSessionLive)
        ZStack(alignment: .bottomLeading) {
            HostArt(scene)
                .id(scene)
                .transition(.opacity)
            VStack(spacing: 6) {
                ForEach(HostSetupPage.allCases) { step in
                    HostRailStep(step: step, isCurrent: step == page,
                                 isComplete: HostSetupFlow.isComplete(step, state: state, current: page))
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HostTheme.railBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Farside.Palette.line).frame(width: 1)
        }
        .animation(reduceMotion ? nil : Farside.Motion.reveal(0.6), value: scene)
    }
}

struct HostRailStep: View {
    let step: HostSetupPage
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isCurrent || isComplete {
                    Circle().fill(Farside.Palette.bone)
                } else {
                    Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1)
                }
                if isComplete && !isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(HostTheme.ink)
                } else {
                    Text(verbatim: "\(step.rawValue + 1)")
                        .font(HostType.caption(10))
                        .foregroundStyle(isCurrent ? HostTheme.ink : Farside.Palette.ash)
                }
            }
            .frame(width: 22, height: 22)
            if isComplete && !isCurrent {
                Text(step.title).hostCaption(12)
            } else {
                Text(step.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? Farside.Palette.bone : Farside.Palette.ash)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Farside.Palette.void2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Farside.Palette.line2, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title), \(isCurrent ? "current step" : isComplete ? "done" : "not done yet")")
    }
}

struct HostDotProgress: View {
    let page: HostSetupPage
    let filled: Int
    let caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "Step \(page.rawValue + 1) of \(HostSetupPage.allCases.count)")
                .hostCaption()
                .fixedSize()
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { index in
                    Circle()
                        .fill(color(index))
                        .frame(width: 6, height: 6)
                }
            }
            Text(caption)
                .hostCaption()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(page.rawValue + 1) of \(HostSetupPage.allCases.count). \(caption)")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func color(_ index: Int) -> Color {
        if index < filled { return Farside.Palette.bone }
        if index == filled { return Farside.Palette.bone.opacity(pulse ? 0.3 : 0.85) }
        return Farside.Palette.dim
    }
}

// MARK: Pages

private enum HostSetupText {
    static func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Farside.Palette.ash)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HostPlate: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Farside.Palette.line, lineWidth: 1))
    }
}

struct HostHelloPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Your Mac is far"), .plain(".\n"), .display("Your reach "),
                                .accent("isn’t"), .plain(".")])
            HostSetupText.body("Farside lets your iPhone see and steer this Mac from wherever you are. Setup takes about a minute.")
                .padding(.top, 12)
            VStack(spacing: 10) {
                item("01", "Two permissions", "One to see the screen, one to steer it.")
                item("02", "One code", "Scan it with Farside on your iPhone. No accounts.")
                item("03", "A ready check", "Farside checks this Mac before you head out.")
            }
            .padding(.top, 22)
        }
    }

    private func item(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: number)
                .font(HostType.caption(12))
                .foregroundStyle(Farside.Palette.ash)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Farside.Palette.ash)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(HostPlate())
        .accessibilityElement(children: .combine)
    }
}

struct HostPermissionsPage: View {
    let state: HostViewState
    let actions: HostActions
    @State private var showsRecoveryLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Two permissions"), .plain(". "), .accent("Then"),
                                .display(" we stop asking"), .plain(".")], size: 30)
            HostSetupText.body("Your Mac checks before anything can see or steer it. Good Mac. Switch both on and this window notices by itself.")
                .padding(.top, 10)
                .padding(.bottom, updateNotice == nil ? 18 : 10)
            if let updateNotice {
                Label(updateNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("farside.setup.updatedMacOS")
            }
            VStack(spacing: 10) {
                HostPermissionRow(
                    title: "Screen Recording", reason: "So your iPhone can see the screen.",
                    symbol: "display", status: state.screenRecording,
                    waiting: state.screenRecordingSettingsOpened,
                    instruction: HostPermissionCopy.switchOn(.screenRecording, listName: state.appListName,
                                                             macOSMajor: state.macOSMajor),
                    showsRecoveryLink: showsRecoveryLink,
                    recovery: HostPermissionCopy.recovery(.screenRecording, listName: state.appListName,
                                                          macOSMajor: state.macOSMajor),
                    open: { actions.openSystemSettings(.screenRecording) },
                    relaunch: actions.relaunch
                )
                .accessibilityIdentifier("farside.setup.screenRecording")
                HostPermissionRow(
                    title: "Accessibility", reason: "So taps become clicks and typing becomes typing.",
                    symbol: "hand.point.up.left", status: state.accessibility,
                    waiting: state.accessibilitySettingsOpened, skipped: state.accessibilitySkipped,
                    instruction: HostPermissionCopy.switchOn(.accessibility, listName: state.appListName,
                                                             macOSMajor: state.macOSMajor),
                    showsRecoveryLink: showsRecoveryLink,
                    recovery: HostPermissionCopy.recovery(.accessibility, listName: state.appListName,
                                                          macOSMajor: state.macOSMajor),
                    open: { actions.openSystemSettings(.accessibility) }
                )
                .accessibilityIdentifier("farside.setup.accessibility")
            }
            if !state.accessibility.isGranted && !state.accessibilitySkipped {
                HStack(spacing: 6) {
                    Text("Not now?")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Farside.Palette.ash)
                    Button("Skip, and your iPhone can only watch", action: actions.skipAccessibility)
                        .buttonStyle(HostButtonStyle(kind: .inline))
                        .accessibilityIdentifier("farside.setup.skipAccessibility")
                }
                .padding(.top, 12)
            }
        }
        .task(id: waiting) {
            showsRecoveryLink = false
            guard waiting else { return }
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { showsRecoveryLink = true }
        }
    }

    private var updateNotice: String? {
        HostCaptureApprovalCopy.afterUpdate(state.permissionsTurnedOffByUpdate, macOSMajor: state.macOSMajor)
    }

    private var waiting: Bool {
        (state.screenRecordingSettingsOpened && !state.screenRecording.isGranted)
            || (state.accessibilitySettingsOpened && !state.accessibility.isGranted)
    }
}

struct HostPermissionRow: View {
    let title: String
    let reason: String
    let symbol: String
    let status: HostPermissionStatus
    var waiting = false
    var skipped = false
    /// Where to look in System Settings, named as it appears there.
    let instruction: String
    var showsRecoveryLink = false
    let recovery: String
    let open: () -> Void
    var relaunch: (() -> Void)?
    @State private var showingRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                HostIconTile(systemImage: symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                    Text(reason)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if status.isGranted {
                    HostGrantedBadge()
                } else {
                    Button("Open Settings", action: open)
                        .buttonStyle(HostArrowButtonStyle())
                        .accessibilityLabel("Open System Settings for \(title)")
                }
            }
            if !status.isGranted && (waiting || skipped) {
                statusLine
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(HostPlate())
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if waiting {
                    ProgressView().controlSize(.mini)
                    Text("Watching for the switch").hostCaption(10.5, color: Farside.Palette.bone)
                } else {
                    Text("Skipped · view only for now").hostCaption(10.5)
                }
                Spacer(minLength: 8)
                if waiting, let relaunch {
                    Button("Quit & Reopen", action: relaunch)
                        .buttonStyle(HostButtonStyle(kind: .inline))
                }
                if waiting && showsRecoveryLink {
                    Button("Still not detected?") { showingRecovery = true }
                        .buttonStyle(HostButtonStyle(kind: .inline))
                        .popover(isPresented: $showingRecovery, arrowEdge: .bottom) {
                            Text(recovery)
                                .font(.system(size: 13))
                                .foregroundStyle(Farside.Palette.bone)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 280)
                                .padding(16)
                                .preferredColorScheme(.dark)
                        }
                }
            }
            if waiting {
                Text(instruction)
                    .font(.system(size: 12))
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 54)
    }
}

struct HostPairingPage: View {
    let state: HostViewState
    let actions: HostActions
    @State private var serviceDraft = ""

    var body: some View {
        switch state.pairing {
        case .awaitingApproval: approval
        case .confirmReplace: replace
        case .needsService: service
        default:
            if state.hasPairedPhone && !state.pairingRequested { paired } else { code }
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("One code"), .plain(". "), .accent("No"), .display(" accounts"), .plain(".")])
            HostSetupText.body("Open Farside on your iPhone, scan this, then approve the phone here. That’s the whole pairing.")
                .padding(.top, 10)
                .padding(.bottom, 20)
            HStack(alignment: .top, spacing: 22) {
                qr
                VStack(alignment: .leading, spacing: 12) {
                    step("1", "Open Farside on your iPhone")
                    step("2", "Scan this code")
                    step("3", "Allow the phone here")
                    expiry
                        .padding(.top, 4)
                }
            }
            if !state.hasPairedPhone {
                HStack(spacing: 6) {
                    Text("No iPhone to hand?")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Farside.Palette.ash)
                    Button("Skip for now, and pair later from the menu bar", action: actions.skipPairing)
                        .buttonStyle(HostButtonStyle(kind: .inline))
                        .accessibilityIdentifier("farside.setup.skipPairing")
                }
                .padding(.top, 18)
            }
        }
        .onChange(of: state.canBeginPairing, initial: true) { _, ready in
            if ready && state.pairing == .idle && !state.hasPairedPhone { actions.beginPairing() }
        }
        .onChange(of: state.pairing) { old, new in
            if HostPairingRefresh.shouldRefresh(from: old, to: new) { actions.beginPairing() }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: number)
                .font(HostType.caption(10))
                .foregroundStyle(Farside.Palette.ash)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Farside.Palette.bone)
        }
        .accessibilityElement(children: .combine)
    }

    private var qr: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Farside.Palette.bone)
            switch state.pairing {
            case .showingCode(let value, _):
                if let image = HostQRCode.image(for: value) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .padding(14)
                        .accessibilityLabel("Private pairing code")
                }
            case .expired:
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22))
                    Text("Code expired").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(HostTheme.ink.opacity(0.7))
            default:
                ProgressView()
                    .controlSize(.regular)
                    .environment(\.colorScheme, .light)
            }
        }
        .frame(width: 176, height: 176)
        .contextMenu {
            if case .showingCode = state.pairing {
                Button("Copy Pairing Code", action: actions.copyPairingCode)
            }
        }
    }

    @ViewBuilder
    private var expiry: some View {
        switch state.pairing {
        case .showingCode(_, let expires):
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(expires.timeIntervalSince(context.date)))
                    Text(verbatim: "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · keep it private")
                        .hostCaption(10.5)
                }
                Button("Copy code instead", action: actions.copyPairingCode)
                    .buttonStyle(HostButtonStyle(kind: .inline))
                    .accessibilityIdentifier("farside.setup.copyCode")
            }
        case .expired:
            VStack(alignment: .leading, spacing: 10) {
                Text("This code no longer works. Make a new one when your iPhone is ready.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                Button("New Code", action: actions.beginPairing)
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 34))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.setup.newCode")
            }
        default:
            Text("Getting a fresh code").hostCaption(10.5)
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Is this"), .accent(" your "), .display("phone"), .plain("?")])
            HostSetupText.body(state.allowControl
                ? "A phone just scanned your code. Once allowed, it can see this screen and use the mouse and keyboard. Allow it only if it’s the phone in your hand."
                : "A phone just scanned your code. Once allowed, it can see this screen. Allow it only if it’s the phone in your hand.")
                .padding(.top, 10)
            HStack(spacing: 10) {
                Button("Decline", action: actions.declinePhone)
                    .buttonStyle(HostButtonStyle(kind: .plate))
                    .accessibilityIdentifier("farside.setup.declinePhone")
                Button("Allow", action: actions.approvePhone)
                    .buttonStyle(HostButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.setup.allowPhone")
            }
            .padding(.top, 22)
            Text("Don’t recognize it? Decline, then make a new code.")
                .font(.system(size: 12.5))
                .foregroundStyle(Farside.Palette.ash)
                .padding(.top, 14)
        }
    }

    private var replace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Pair a"), .accent(" new "), .display("phone"), .plain("?")])
            HostSetupText.body("Your current iPhone will stop working with this Mac. You can pair it again later.")
                .padding(.top, 10)
            HStack(spacing: 10) {
                Button("Cancel", action: actions.cancelPairing)
                    .buttonStyle(HostButtonStyle(kind: .plate))
                    .accessibilityIdentifier("farside.setup.cancelPairing")
                Button("Replace Phone", action: actions.beginPairing)
                    .buttonStyle(HostButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.setup.replacePhone")
            }
            .padding(.top, 22)
        }
    }

    private var service: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("One address"), .plain(", "), .accent("please"), .plain(".")])
            HostSetupText.body("This test build doesn’t include a connection service yet. Enter the private service address you were given.")
                .padding(.top, 10)
            HStack(spacing: 10) {
                TextField("wss://example.com/signal", text: $serviceDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { actions.setServiceAddress(serviceDraft) }
                Button("Continue") { actions.setServiceAddress(serviceDraft) }
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 30))
                    .disabled(!PairInvitation.validServer(serviceDraft.trimmingCharacters(in: .whitespaces)))
            }
            .padding(.top, 20)
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Your iPhone is"), .accent(" paired"), .plain(".")])
            HostSetupText.body("It can connect whenever sharing is on. Pairing a different phone replaces this one.")
                .padding(.top, 10)
            Button("Pair a Different Phone…", action: actions.pairNewPhone)
                .buttonStyle(HostButtonStyle(kind: .plate, height: 34))
                .padding(.top, 20)
        }
    }
}

struct HostReadyPage: View {
    let state: HostViewState
    let actions: HostActions

    var body: some View {
        let checks = HostReadyCheck.checks(for: state)
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: HostReadyCheck.isReady(checks)
                ? [.display("Ready when"), .accent(" you "), .display("are"), .plain(".")]
                : [.display("Almost"), .accent(" there"), .plain(".")])
            HostSetupText.body("Checked just now, on this Mac. Each row updates by itself.")
                .padding(.top, 8)
                .padding(.bottom, 14)
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 {
                        Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 44)
                    }
                    HostCheckRow(check: check, state: state, actions: actions)
                }
            }
            .modifier(HostPlate())
        }
    }
}

struct HostCheckRow: View {
    let check: HostReadyCheck
    let state: HostViewState
    let actions: HostActions

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                Text(check.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(resultLabel)
            Spacer(minLength: 8)
            fix
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var resultLabel: String {
        switch check.result {
        case .pass: "Passed"
        case .waiting: "Checking"
        case .optional: "Optional"
        case .fail: "Needs attention"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch check.result {
        case .pass:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(HostTheme.ink)
                .frame(width: 18, height: 18)
                .background(Farside.Palette.bone, in: Circle())
        case .waiting:
            ProgressView().controlSize(.mini)
        case .optional:
            Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1.2)
        case .fail:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Farside.Palette.bone, lineWidth: 1.2))
        }
    }

    @ViewBuilder
    private var fix: some View {
        switch check.fix {
        case .openSettings(let pane):
            Button("Open Settings") { actions.openSystemSettings(pane) }
                .buttonStyle(HostButtonStyle(kind: .plate, height: 28))
        case .allowControl:
            HostSwitch(label: "Allow control", isOn: state.allowControl, set: actions.setAllowControl)
        case .openAtLogin:
            HostSwitch(label: "Open at login", isOn: state.openAtLogin, set: actions.setOpenAtLogin)
        case .resumeSharing:
            Button("Resume", action: actions.resumeSharing)
                .buttonStyle(HostButtonStyle(kind: .plate, height: 28))
        case .tryAgain:
            Button("Try Again", action: actions.resumeSharing)
                .buttonStyle(HostButtonStyle(kind: .plate, height: 28))
        case .pairPhone:
            Button("Pair", action: actions.pairNewPhone)
                .buttonStyle(HostButtonStyle(kind: .plate, height: 28))
        case nil:
            EmptyView()
        }
    }
}
