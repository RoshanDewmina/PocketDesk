import Foundation
import Network

/// Discovery returns locators only. No TXT/hostname/display name is promoted into saved trust.
@MainActor
final class LocalMacDiscovery {
    static let serviceType = "_farside._tcp"
    var onResults: (([NWBrowser.Result]) -> Void)?
    var onFailure: (() -> Void)?
    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        stop()
        let run = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.onResults?(Array(results.prefix(32)))
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    self.stop(); self.onFailure?()
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "farside.local-discovery"))
    }
    func stop() {
        generation = UUID(); browser?.cancel(); browser = nil
        onResults?([])
    }
}
