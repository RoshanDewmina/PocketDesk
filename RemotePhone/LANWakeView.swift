import SwiftUI

struct LANWakeView: View {
    @ObservedObject var model: PhoneRemoteModel
    @State private var target = ""
    @State private var confirm = false
    var body: some View {
        Form {
            Section("Powered LAN helper") {
                Text(model.connection.invitation?.name ?? "Select your paired helper Mac")
                Text("Connect to your paired, powered helper first. Register the sleeping Mac locally in that helper’s Farside Availability settings, then copy its opaque wake target ID here.")
                TextField("Owner-registered wake target ID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Send wake packet") { confirm = true }
                    .frame(minHeight: 44).disabled(!model.canRequestLANWake || UUID(uuidString: target) == nil)
                Text(model.wakeStatus ?? "A packet can request supported network wake. It cannot unlock the Mac or confirm it is awake.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("After sending") {
                Text("End this helper session, choose the target Mac in Your Macs, and Connect. Only that Mac’s own authenticated connection and fresh content establish availability. Network wake settings, hardware and subnet support still apply.")
            }
        }
        .navigationTitle("LAN wake")
        .confirmationDialog("Send one wake packet through this paired helper?", isPresented: $confirm) {
            Button("Send packet") { if let id = UUID(uuidString: target) { model.requestLANWake(targetID: id) } }
        } message: {
            Text("The helper accepts only targets locally registered by its owner. This does not change the sleeping Mac’s password, pairing or lock.")
        }
    }
}
