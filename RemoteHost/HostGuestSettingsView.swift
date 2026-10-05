import SwiftUI

struct HostGuestSettingsView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var confirming: HostGuestRow?
    var body: some View {
        HostSettingsSection("Guest viewing", footer: state.guestMessage ?? "Up to two guests can view video for ten minutes while your paid remote session is live. Guests have no audio or control. Changing shared content or ending the session ends every guest. A recipient can record pixels already received.") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Create guest link", action: actions.createGuestLink)
                    .disabled(!state.guestViewingAvailable || state.guestRows.count >= 2)
                ForEach(state.guestRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.status)
                        Text(row.remainingSeconds > 0 ? "Ends in \(row.remainingSeconds / 60)m \(row.remainingSeconds % 60)s" : "Expired · create a fresh link")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Remaining guest lifetime: \(row.remainingSeconds) seconds")
                        if row.pending { Text("Recipient key: \(row.fingerprint)").font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityLabel("Full recipient key fingerprint: \(row.fingerprint)") }
                        HStack {
                            if row.linkReady { Button("Copy link") { actions.copyGuestLink(row.id) } }
                            if row.pending { Button("Review approval") { confirming = row } }
                            Button(row.pending ? "Decline" : "End guest") { actions.revokeGuest(row.id) }
                        }
                    }
                }
            }.padding(14)
        }
        .alert("Approve this recipient for video viewing?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Approve viewing") {
                if let row = confirming, state.guestRows.contains(where: { $0.id == row.id && $0.pending && $0.fingerprint == row.fingerprint }) { actions.approveGuest(row.id) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Verify this full key fingerprint with the recipient through a channel you trust:\n\(confirming?.fingerprint ?? "")\n\nViewing ends after ten minutes or when the current session or shared content changes. Audio and control are unavailable.")
        }
    }
}
