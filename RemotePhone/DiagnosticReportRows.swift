import SwiftUI

struct DiagnosticReportRows: View {
    @ObservedObject var model: PhoneRemoteModel
    var body: some View { DiagnosticReportContent(diagnostics: model.diagnostics, start: { model.testMyMac(full: $0) }, connected: model.connection.connected) }
}
private struct DiagnosticReportContent: View {
    @ObservedObject var diagnostics: PhoneDiagnostics
    let start: (Bool) -> Void
    let connected: Bool
    var body: some View {
        Button("Test My Mac · light") { start(false) }.disabled(!connected || diagnostics.running)
        Button("Full session preflight") { start(true) }.disabled(!connected || diagnostics.running)
        if diagnostics.running { Button("Cancel check", role: .cancel) { diagnostics.cancel() } }
        Text(diagnostics.status).font(.footnote)
        Text("Checks authenticated replies and current session health. No throughput, input-event or physical latency test. Up to 8 small probes over 8 seconds.").font(.footnote)
        Text("Reports stay here for 7 days, up to 10 reports. Preview before sharing. No automatic upload.").font(.footnote)
        ForEach(diagnostics.reports) { report in
            DisclosureGroup("\(report.kind.rawValue) · \(report.outcome.rawValue)") {
                Text(report.preview).font(.footnote).textSelection(.enabled)
                ShareLink(item: report.preview) { Label("Export this preview", systemImage: "square.and.arrow.up") }
                Button("Delete report", role: .destructive) { diagnostics.delete(report.id) }
            }
        }
        if !diagnostics.reports.isEmpty { Button("Delete all local reports", role: .destructive) { diagnostics.deleteAll() } }
    }
}
