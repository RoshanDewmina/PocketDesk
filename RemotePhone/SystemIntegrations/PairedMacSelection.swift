import SwiftUI

extension PhoneRemoteModel {
    /// All destination changes end the old session and release held input BEFORE Keychain selection.
    /// A failed write leaves the old pair safe and stopped; it never starts a replacement implicitly.
    @discardableResult
    func selectPairedMac(id: String, trust: PhoneTrustStore = .shared) -> Bool {
        do {
            let snapshot = try trust.snapshot()
            guard let host = snapshot.hosts.first(where: { "m_" + $0.id == id || $0.legacyAliases.contains(id) }) else {
                throw RemoteError.invalidPairing
            }
            if snapshot.selectedHostID == host.id, connection.invitation == host.invitation { return true }
            disconnect()
            try trust.select(hostID: host.id)
            connection.restore()
            vitalsMemory.forget()
            refreshSendToMac(force: true)
            return connection.invitation == host.invitation
        } catch {
            error = error.localizedDescription
            return false
        }
    }
}

/// The caller presents this from Home. Selection changes the saved destination; Connect remains
/// an explicit user action, including the existing unlock/server-removal gates.
struct PairedMacSelectionSheet: View {
    @ObservedObject var model: PhoneRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var macs: [PairedMac] = []

    var body: some View {
        NavigationStack {
            List(macs, id: \.id) { mac in
                Button {
                    if model.selectPairedMac(id: mac.id) { dismiss() }
                } label: {
                    HStack {
                        Label(mac.name, systemImage: "laptopcomputer")
                        Spacer()
                        if model.connection.invitation == mac.invitation {
                            Image(systemName: "checkmark").accessibilityLabel("Selected")
                        }
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("pairedMac.select." + mac.id)
            }
            .navigationTitle("Your Macs")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { macs = PairedMacs.all() }
        }
    }
}
