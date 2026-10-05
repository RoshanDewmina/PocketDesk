import AppKit
import SwiftUI
import Combine
import Sparkle

/// Development builds never replace the permission-stable local host through the release feed.
@MainActor
final class HostUpdateController: ObservableObject {
    static let shared = HostUpdateController()
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    private init() {
        guard !FarsideBeta.isEnabled else { return }
        #if !DEBUG
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == "https://getfarside.com/mac/appcast.xml" else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = updater
        observation = updater.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
        #endif
    }

    func check() { guard canCheck else { return }; controller?.checkForUpdates(nil) }
}

struct HostUpdateButton: View {
    @ObservedObject private var updater = HostUpdateController.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}
