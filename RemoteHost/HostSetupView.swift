import SwiftUI

struct HostSetupView: View {
    let state: HostViewState
    let actions: HostActions

    var body: some View {
        VStack(spacing: 0) {
            HostSetupProgress(current: state.setupStep)
                .padding(.top, 18)
                .padding(.horizontal, 28)

            Group {
                switch state.setupStep {
                case .screenRecording: screenRecordingStep
                case .accessibility: accessibilityStep
                case .pairPhone: HostPairingStep(state: state, actions: actions)
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 26)
            .padding(.bottom, 18)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 540, height: 450)
        .animation(.smooth, value: state.setupStep)
    }

    private var screenRecordingStep: some View {
        HostSetupPage(
            systemImage: "rectangle.dashed.badge.record", tone: .sand,
            title: "Allow Screen Recording",
            message: "PocketDesk streams this Mac’s screen to your phone. macOS asks you to allow this once, in System Settings."
        ) {
            if state.screenRecording.isGranted {
                HostStatusLine(kind: .done, text: "Screen Recording is allowed")
            } else if state.screenRecordingSettingsOpened {
                HostStatusLine(kind: .waiting, text: "Turn on PocketDesk Host in the list. This page updates by itself.")
                recoveryNote(relaunchHint: true)
            }
        }
    }

    private var accessibilityStep: some View {
        HostSetupPage(
            systemImage: "cursorarrow.rays", tone: .blue,
            title: "Allow mouse and keyboard",
            message: "So your phone can click, scroll and type on this Mac, turn on PocketDesk Host under Accessibility. You can turn control off in Settings or stop sharing from the menu bar."
        ) {
            if state.accessibility.isGranted {
                HostStatusLine(kind: .done, text: "Accessibility is allowed")
            } else if state.accessibilitySettingsOpened {
                HostStatusLine(kind: .waiting, text: "Turn on PocketDesk Host in the list. This page updates by itself.")
                recoveryNote(relaunchHint: false)
            }
        }
    }

    private var doneStep: some View {
        HostSetupPage(
            systemImage: "checkmark", tone: .sage,
            title: "PocketDesk is ready",
            message: "Open PocketDesk on your phone to see and use this Mac. While PocketDesk is running, you’ll find it in the menu bar."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                hint("macbook.and.iphone", "The menu bar icon changes whenever your phone is viewing or controlling this Mac.")
                hint("pause.circle", "Choose Stop Sharing in that menu to end a session at once.")
                Toggle("Open PocketDesk when you log in",
                       isOn: Binding(get: { state.openAtLogin }, set: actions.setOpenAtLogin))
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func hint(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recoveryNote(relaunchHint: Bool) -> some View {
        Text(relaunchHint
             ? "Already on? Quit and reopen PocketDesk. If it still isn’t detected, select PocketDesk Host in the list, remove it with the – button, add it again with +, then reopen PocketDesk."
             : "Already on? Select PocketDesk Host in the list, remove it with the – button, then add it again with +.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch state.setupStep {
            case .screenRecording:
                if state.screenRecordingSettingsOpened && !state.screenRecording.isGranted {
                    Button("Quit & Reopen", action: actions.relaunch)
                }
                Spacer()
                Button("Open System Settings") { actions.openSystemSettings(.screenRecording) }
                    .keyboardShortcut(.defaultAction)
            case .accessibility:
                Button("Skip — View Only", action: actions.skipAccessibility)
                Spacer()
                Button("Open System Settings") { actions.openSystemSettings(.accessibility) }
                    .keyboardShortcut(.defaultAction)
            case .pairPhone:
                if state.pairing == .confirmReplace {
                    Button("Cancel", action: actions.cancelPairing)
                }
                Spacer()
                if state.pairing == .confirmReplace {
                    Button("Replace Phone", action: actions.beginPairing).keyboardShortcut(.defaultAction)
                }
                if case .expired = state.pairing {
                    Button("New Code", action: actions.beginPairing).keyboardShortcut(.defaultAction)
                }
            case .done:
                Spacer()
                Button("Done", action: actions.finishSetup)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

struct HostSetupPage<Content: View>: View {
    let systemImage: String
    let tone: HostTone
    let title: String
    let message: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HostIconTile(systemImage: systemImage, tone: tone)
            Text(title)
                .font(.hostTitle)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HostSetupProgress: View {
    @Environment(\.colorScheme) private var scheme
    let current: HostSetupStep

    private let steps: [(HostSetupStep, String)] = [
        (.screenRecording, "Screen"),
        (.accessibility, "Control"),
        (.pairPhone, "Phone"),
        (.done, "Ready")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(item.0 <= current ? HostTone.sage.ink(scheme).opacity(0.5) : Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: 36)
                }
                HStack(spacing: 5) {
                    Image(systemName: symbol(for: item.0))
                        .foregroundStyle(item.0 < current || current == .done ? HostTone.sage.ink(scheme)
                                         : item.0 == current ? Color.accentColor : Color.secondary)
                    Text(item.1)
                        .foregroundStyle(item.0 == current ? .primary : .secondary)
                }
                .font(.caption.weight(item.0 == current ? .semibold : .regular))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(current.rawValue + 1) of \(HostSetupStep.allCases.count)")
    }

    private func symbol(for step: HostSetupStep) -> String {
        if step < current || current == .done { return "checkmark.circle.fill" }
        return step == current ? "circle.inset.filled" : "circle"
    }
}

struct HostPairingStep: View {
    let state: HostViewState
    let actions: HostActions
    @State private var serviceDraft = ""

    var body: some View {
        switch state.pairing {
        case .awaitingApproval:
            approval
        case .confirmReplace:
            HostSetupPage(systemImage: "iphone.gen3", tone: .clay, title: "Pair a new phone?",
                          message: "Your current iPhone will stop working with this Mac. You can pair it again later.") {
                EmptyView()
            }
        case .needsService:
            HostSetupPage(systemImage: "network", tone: .clay, title: "Connection service needed",
                          message: "This test build doesn’t include a connection service yet. Enter the private service address you were given.") {
                HStack {
                    TextField("wss://example.com/signal", text: $serviceDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { actions.setServiceAddress(serviceDraft) }
                    Button("Continue") { actions.setServiceAddress(serviceDraft) }
                        .disabled(!PairInvitation.validServer(serviceDraft.trimmingCharacters(in: .whitespaces)))
                }
            }
        default:
            code
        }
    }

    private var code: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                HostIconTile(systemImage: "iphone.gen3", tone: .sage)
                Text("Pair your phone")
                    .font(.hostTitle)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open PocketDesk on your iPhone.")
                    Text("2. Scan this code with it.")
                    Text("3. Allow the phone here on your Mac.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                expiry
                    .padding(.top, 6)
            }
            qr
        }
        .onChange(of: state.canBeginPairing, initial: true) { _, ready in
            if ready && state.pairing == .idle && !state.hasPairedPhone { actions.beginPairing() }
        }
    }

    @ViewBuilder
    private var qr: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
                    Image(systemName: "clock.arrow.circlepath").font(.title)
                    Text("Code expired").font(.callout)
                }
                .foregroundStyle(.black.opacity(0.55))
            default:
                ProgressView().controlSize(.regular)
            }
        }
        .frame(width: 196, height: 196)
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expires.timeIntervalSince(context.date)))
                Label("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · Keep it private",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .expired:
            Text("Codes last two minutes. Make a new one when your phone is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var approval: some View {
        HostSetupPage(
            systemImage: "person.crop.circle.badge.questionmark", tone: .clay,
            title: "Allow this phone?",
            message: state.allowControl
                ? "A phone scanned your code. Once allowed, it can see this Mac’s screen and use its mouse and keyboard. Allow it only if it’s the phone in your hand."
                : "A phone scanned your code. Once allowed, it can see this Mac’s screen. Allow it only if it’s the phone in your hand."
        ) {
            HStack(spacing: 10) {
                Button("Decline", action: actions.declinePhone)
                Button("Allow", action: actions.approvePhone)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}
