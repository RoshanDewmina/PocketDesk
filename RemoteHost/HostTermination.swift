import AppKit
import Darwin
import Dispatch

@MainActor
final class HostTerminationLifecycle {
    private let cleanup: () -> Void
    private var didCleanUp = false
    private var didRequestTermination = false

    init(cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func applicationWillTerminate() {
        guard !didCleanUp else { return }
        didCleanUp = true
        cleanup()
    }

    func requestTermination(using terminate: () -> Void) {
        guard !didRequestTermination else { return }
        didRequestTermination = true
        applicationWillTerminate()
        terminate()
    }
}

@MainActor
final class RemoteHostAppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: HostTerminationLifecycle?
    private var sigtermSource: DispatchSourceSignal?

    func configure(cleanup: @escaping () -> Void) {
        guard lifecycle == nil else { return }
        lifecycle = HostTerminationLifecycle(cleanup: cleanup)

        _ = Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleSIGTERM() }
        }
        source.resume()
        sigtermSource = source
    }

    var onLaunch: (() -> Void)?
    var onReopen: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { onReopen?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle?.applicationWillTerminate()
    }

    private func handleSIGTERM() {
        lifecycle?.requestTermination {
            NSApplication.shared.terminate(nil)
        }
    }
}
