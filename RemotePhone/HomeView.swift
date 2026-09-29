import SwiftUI

struct PhoneRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator

    var body: some View {
        Group {
            if connection.connected || connection.remoteVideo != nil {
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
                HomeView(model: model, connection: connection)
            }
        }
    }
}

/// Debug-only launch switches used by UI tests and simulator screenshots.
enum LaunchOptions {
    static var layoutCheck: Bool { has("--ui-layout-check") }
    static var demoMacName: String? { has("--ui-demo-mac") ? "MacBook Air" : nil }
    static var viewportOverride: ViewportMode? {
        has("--ui-viewport-fit") ? .fit : has("--ui-viewport-fill") ? .fill : nil
    }

    private static func has(_ argument: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }
}

struct HomeView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    @State private var showDetails = false
    @State private var confirmForget = false

    private var macName: String? { connection.invitation?.name ?? LaunchOptions.demoMacName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let macName {
                        MacCard(name: macName, status: MacStatus(connection.status),
                                connect: { connection.start() }, cancel: model.disconnect)
                    } else {
                        addMacCard
                    }
                    if let notice = model.macNotice {
                        Label(notice, systemImage: "moon.zzz")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.error.isEmpty {
                        Label(model.error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(PhoneTheme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label("Keep your Mac awake and unlocked while you use PocketDesk. Away access needs the remote service.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(PhoneTheme.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { moreMenu } }
            .accessibilityIdentifier("phone.home")
        }
        .sheet(item: $model.pairingEntry) { entry in
            PairingSheet(model: model, entry: entry)
        }
        .sheet(isPresented: $showDetails) {
            ConnectionDetailsSheet(connection: connection)
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) { connection.revoke() }
        } message: {
            Text("You’ll need to scan a new pairing code on your Mac to connect again.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PocketDesk")
                .font(PhoneTheme.titleFont)
                .accessibilityAddTraits(.isHeader)
            Text(macName == nil ? "Your Mac, within reach." : "Pick up where you left off.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var addMacCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PhoneTheme.tint)
                .padding(.top, 8)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Add your Mac")
                    .font(.title2.weight(.semibold))
                Text("On your Mac, open PocketDesk and click Pair a phone. Then scan the code it shows.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                Button { model.pairingEntry = .scan } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Paste a pairing code") { model.pairingEntry = .paste }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(PhoneTheme.card, in: .rect(cornerRadius: 28, style: .continuous))
    }

    private var moreMenu: some View {
        Menu {
            Button { model.pairingEntry = .scan } label: {
                Label(macName == nil ? "Pair a Mac" : "Pair Again", systemImage: "qrcode.viewfinder")
            }
            Button { model.pairingEntry = .paste } label: {
                Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
            }
            Button { showDetails = true } label: {
                Label("Connection Details", systemImage: "network")
            }
            if connection.invitation != nil {
                Divider()
                Button(role: .destructive) { confirmForget = true } label: {
                    Label("Forget Mac", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }
}

struct MacStatus: Equatable {
    enum Tone { case idle, busy, caution }
    let text: String
    let tone: Tone
    let needsApproval: Bool

    init(_ raw: String) {
        switch raw {
        case "Ready to connect", "Disconnected", "Not connected":
            self.init(text: "Ready to connect", tone: .idle)
        case "Approve this phone on your Mac":
            self.init(text: "Approve this iPhone on your Mac", tone: .busy, needsApproval: true)
        default:
            if raw.hasPrefix("Connecting") || raw.hasPrefix("Authenticating") {
                self.init(text: raw, tone: .busy)
            } else if raw.contains("retrying") {
                self.init(text: raw, tone: .busy)
            } else {
                self.init(text: raw, tone: .caution)
            }
        }
    }

    private init(text: String, tone: Tone, needsApproval: Bool = false) {
        self.text = text
        self.tone = tone
        self.needsApproval = needsApproval
    }

    var color: Color {
        switch tone {
        case .idle: .secondary
        case .busy: PhoneTheme.busy
        case .caution: PhoneTheme.caution
        }
    }
}

/// A saved-device card, after Apple Home accessory tiles and Find My device sheets.
struct MacCard: View {
    let name: String
    let status: MacStatus
    let connect: () -> Void
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(PhoneTheme.tint)
                    .frame(width: 54, height: 54)
                    .background(PhoneTheme.tint.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if status.tone == .busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            StatusDot(color: status.color)
                        }
                        Text(status.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            if status.needsApproval {
                Label("Check your Mac and click Approve.", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PhoneTheme.busy.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
            }
            if status.tone == .busy {
                Button(action: cancel) {
                    Text("Cancel connection").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else {
                Button(action: connect) {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(PhoneTheme.card, in: .rect(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.mac")
    }
}

private struct ConnectionDetailsSheet: View {
    @ObservedObject var connection: RemoteCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Text(connection.diagnostics)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Section {
                    Toggle("Relay-only test", isOn: Binding(get: { connection.forceRelay },
                                                              set: { connection.forceRelay = $0 }))
                        .disabled(connection.connected)
                } footer: {
                    Text("For testing the relay route. Leave off for normal use.")
                }
            }
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ConcealedRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator

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
        case .reconnectFailed: "Couldn’t reconnect"
        case .ended: "Session ended"
        }
    }

    private var message: String {
        switch presentation {
        case .hidden: "PocketDesk hides your Mac’s screen while it’s in the background."
        case .reconnecting: "Resuming your session with \(macName). Your pairing is kept."
        case .reconnectFailed: model.macNotice ?? MacStatus(connection.status).text
        case .ended: "PocketDesk hid your Mac’s screen while it was in the background. Reconnect to continue."
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Group {
                if presentation == .reconnecting {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(PhoneTheme.tint)
                }
            }
            .frame(width: 76, height: 76)
            .background(PhoneTheme.tint.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                switch presentation {
                case .hidden:
                    EmptyView()
                case .reconnecting:
                    Button(action: model.dismissConcealment) {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                case .reconnectFailed, .ended:
                    if canReconnect {
                        Button(action: model.reconnect) {
                            Text("Reconnect").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    Button(action: model.dismissConcealment) {
                        Text("Return to PocketDesk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneTheme.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.concealed")
    }
}
