import SwiftUI

/// Separate from local Forget: success here means the service confirmed device unlinking.
struct ServerDataRemovalView: View {
    @ObservedObject var connection: RemoteCoordinator
    @ObservedObject var access: AnywhereAccess
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    @State private var completed = false
    @State private var removedPairing: PairInvitation?
    @State private var cleanupPending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Remove this iPhone or iPad’s Anywhere link and end its remote session. This frees its subscription device slot. Your Mac’s room is removed separately in the Mac app.")
                    Text("This does not cancel your Apple subscription. Purchase records remain for up to 90 days after access ends; security blocks and pending relay revocations may be retained.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if completed {
                        Label("Device unlink confirmed", systemImage: "checkmark.circle")
                        if cleanupPending {
                            Text("The server removed this device link, but its local pairing could not be cleared. Unlock your device and retry.")
                                .font(.footnote)
                            Button("Retry Local Cleanup") { clearOriginalPairing() }
                        }
                    } else {
                        Button(access.removalPending ? "Retry Server Removal" : "Remove Device Link…", role: .destructive) { confirming = true }
                            .disabled(busy)
                            .accessibilityIdentifier("privacy.removeDevice")
                        if access.removalRecoveryRequired {
                            Text("Saved removal status could not be read. Unlock your device and retry. Verification stays paused until you retry or explicitly cancel removal.")
                                .font(.footnote)
                        }
                        if busy { ProgressView("Waiting for server confirmation…") }
                        if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("privacy.removalError") }
                        if access.removalPending && !busy {
                            Button("Cancel Removal and Keep Pairing") {
                                do { try access.cancelRemoval(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Server Data")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .confirmationDialog("Remove this device’s Anywhere link?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove Device Link", role: .destructive) {
                    busy = true; error = nil
                    removedPairing = connection.invitation
                    connection.stop()
                    Task { @MainActor in
                        do {
                            try await access.unlinkDevice()
                            clearOriginalPairing()
                            completed = true
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            } message: { Text("The session ends now. Saved removal proof is kept until the service confirms success.") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func clearOriginalPairing() {
        guard connection.invitation == removedPairing else {
            // A newer pairing must never be cleared by an older unlink response.
            cleanupPending = false
            return
        }
        connection.revoke()
        cleanupPending = connection.invitation != nil
    }

}
