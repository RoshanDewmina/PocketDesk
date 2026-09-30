import Foundation

/// This iPhone's own link, as a Connection Health hint ("Weak Wi-Fi", "Cellular / expensive",
/// "Very constrained link — picture limited"). Display only: it never decides access or routing.
@MainActor
final class PhoneLinkHintMonitor: ObservableObject {
    @Published private(set) var hint: NetworkLinkHint?
    private let watcher = NetworkPathWatcher()

    func start() {
        watcher.onLinkChange = { [weak self] hint in self?.hint = hint }
        watcher.start()
    }

    func stop() {
        watcher.stop()
        hint = nil
    }
}
