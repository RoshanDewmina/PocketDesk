import Foundation

/// This iPhone's own link, as a Connection Health hint ("Weak Wi-Fi", "Cellular / expensive",
/// "Very constrained link — picture limited"). Also carries Low Data Mode for negotiated media; never decides access or routing.
@MainActor
final class PhoneLinkHintMonitor: ObservableObject {
    @Published private(set) var hint: NetworkLinkHint?
    private let watcher = NetworkPathWatcher()

    func start() {
        watcher.onLinkChange = { [weak self] hint in self?.hint = hint }
        watcher.start()
    }

    #if DEBUG
    func observeForTesting(_ reading: NetworkLinkReading) { watcher.observeLink(reading) }
    #endif

    func stop() {
        watcher.stop()
        hint = nil
    }
}
