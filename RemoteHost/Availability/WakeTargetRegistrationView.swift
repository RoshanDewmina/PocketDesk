import SwiftUI

/// Local registration is deliberate. Parent supplies authenticated helper/grant identity;
/// this view never derives authority from a name, hardware address or remote request.
struct WakeTargetRegistrationView: View {
    let helperHostID: String
    let ownerPairID: String
    let store: HostWakeTargetStore
    @State private var targets: [HostWakeTarget] = []
    @State private var targetHost = ""
    @State private var hardwareAddress = ""
    @State private var interfaceName = "en0"
    @State private var error: String?
    @State private var registering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wake another Mac on this LAN").font(.title2).accessibilityAddTraits(.isHeader)
            Text("This Mac must stay powered and awake. The other Mac needs supported network wake with Wake for network access enabled. Sending a packet never unlocks the Mac or proves it woke.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(targets.filter { $0.helperHostID == helperHostID && $0.ownerPairID == ownerPairID }) { target in
                HStack {
                    Text(target.id.uuidString.lowercased()).textSelection(.enabled)
                    Spacer()
                    Button("Remove") { do { try store.remove(target.id); refresh() } catch { self.error = "Couldn’t update wake registrations. Existing records were retained." } }
                }
            }
            TextField("Other Mac’s durable host ID", text: $targetHost)
            TextField("Other Mac’s network hardware address", text: $hardwareAddress)
            TextField("This Mac’s LAN interface", text: $interfaceName)
            Text("Enter the owner-verified ID and address locally. Discovery names are not proof. Registration permits your currently paired owner to request one wake packet per minute to this target.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Register wake target") { registering = true }
                .disabled(!WakeIdentity.valid(targetHost) || (try? WakeHardwareAddress(hardwareAddress)) == nil || WakeLANInterface.current(named: interfaceName) == nil)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(24).frame(width: 620).onAppear(perform: refresh)
        .confirmationDialog("Allow your paired owner to wake this target through this Mac?", isPresented: $registering) {
            Button("Register") { register() }
        } message: {
            Text("This grants packet sending only. Removal or pairing revocation removes eligibility. The sleeping Mac still uses its own pairing and login security.")
        }
    }
    private func refresh() {
        do { targets = try store.read(); error = nil }
        catch { self.error = "Wake records are unreadable. Registration is unavailable; existing data was retained." }
    }
    private func register() {
        do {
            guard WakeIdentity.valid(targetHost), WakeLANInterface.current(named: interfaceName) != nil else { throw WakeConfigurationError.invalid }
            try store.register(HostWakeTarget(id: UUID(), targetHostID: targetHost, helperHostID: helperHostID,
                                             ownerPairID: ownerPairID, hardwareAddress: WakeHardwareAddress(hardwareAddress), interfaceName: interfaceName),
                               helperHostID: helperHostID, ownerPairID: ownerPairID)
            hardwareAddress = ""; targetHost = ""; refresh()
        } catch { self.error = "Couldn’t register this owner-verified target. Check the IDs, address and current LAN interface." }
    }
}
