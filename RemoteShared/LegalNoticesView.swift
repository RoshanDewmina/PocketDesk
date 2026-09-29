import SwiftUI

struct LegalNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party notices are unavailable in this build."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(notices)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .navigationTitle("Third-Party Notices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 520)
        #endif
    }
}
