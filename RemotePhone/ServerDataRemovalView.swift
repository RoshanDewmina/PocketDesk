import SwiftUI

/// Separate from local Forget: success here means the service confirmed device unlinking.
struct ServerDataRemovalView: View {
    @ObservedObject var connection: RemoteCoordinator
    @ObservedObject var access: AnywhereAccess
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    @State private var newerPairingKept = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Remove this iPhone or iPad’s Anywhere link and end its remote session. This frees its subscription device slot. Your Mac’s room is removed separately in the Mac app.")
                    Text("This does not cancel your Apple subscription. Purchase records remain for up to 90 days after access ends; security blocks and pending relay revocations may be retained.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if access.removalCompleted {
                        Label("Device unlink confirmed", systemImage: "checkmark.circle")
                        if access.localCleanupPending {
                            Text("The server removed this device link, but its local pairing could not be cleared. Unlock your device and retry.")
                                .font(.footnote)
                            Button("Retry Local Cleanup") { retryLocalCleanup() }
                        } else if newerPairingKept {
                            Text("A newer Mac pairing was kept. The removed device link remains unlinked.")
                                .font(.footnote)
                        }
                    } else {
                        if access.removalRecoveryRequired {
                            Text("Saved removal status could not be read. Unlock your device and retry. Connection stays paused until its state is recovered.")
                                .font(.footnote)
                            Button("Retry Saved Removal Status") {
                                do { try access.recoverRemovalState(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        } else {
                            Button(access.removalPending ? "Retry Server Removal" : "Remove Device Link…", role: .destructive) { confirming = true }
                                .disabled(busy)
                                .accessibilityIdentifier("privacy.removeDevice")
                        }
                        if busy { ProgressView("Waiting for server confirmation…") }
                        if access.removalPending && !access.removalRecoveryRequired && !busy {
                            Button("Cancel Removal and Keep Pairing") {
                                do { try access.cancelRemoval(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("privacy.removalError") }
                }
            }
            .navigationTitle("Server Data")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .confirmationDialog("Remove this device’s Anywhere link?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove Device Link", role: .destructive) {
                    let pairing: PairInvitation?
                    do { pairing = try connection.phonePairingForRemoval() }
                    catch { self.error = error.localizedDescription; return }
                    busy = true; error = nil
                    connection.stop()
                    Task { @MainActor in
                        do {
                            try await access.unlinkDevice(pairing: pairing)
                            try clearOriginalPairingIfNeeded()
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            } message: { Text("The session ends now. Saved removal proof is kept until the service confirms success.") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func retryLocalCleanup() {
        do { try clearOriginalPairingIfNeeded(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func clearOriginalPairingIfNeeded() throws {
        guard let pairing = access.cleanupPairing else { return }
        let removed = try connection.removePhonePairingIfMatching(
            room: pairing.room, server: pairing.server, tokenDigest: pairing.tokenDigest)
        try access.acknowledgeLocalCleanup(pairing)
        newerPairingKept = !removed
    }
}
