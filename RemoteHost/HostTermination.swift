import AppKit
import Darwin
import Dispatch

@MainActor
final class HostTerminationLifecycle {
    private let cleanup: () -> Void
    private let prepare: (@escaping (Bool) -> Void) -> Bool
    private var didCleanUp = false
    private var didRequestTermination = false

    init(prepare: @escaping (@escaping (Bool) -> Void) -> Bool = { _ in false }, cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
        self.prepare = prepare
    }

    func applicationWillTerminate() {
        guard !didCleanUp else { return }
        didCleanUp = true
        cleanup()
    }

    func requestTermination(using terminate: () -> Void) {
        guard !didRequestTermination else { return }
        didRequestTermination = true
        terminate()
    }

    func shouldTerminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !didCleanUp else { return .terminateNow }
        if prepare({ [weak self] allowed in
            if !allowed { self?.didRequestTermination = false }
            reply(allowed)
        }) { return .terminateLater }
        return .terminateNow
    }
}

@MainActor
final class RemoteHostAppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: HostTerminationLifecycle?
    private var sigtermSource: DispatchSourceSignal?

    func configure(cleanup: @escaping () -> Void, prepare: @escaping (@escaping (Bool) -> Void) -> Bool = { _ in false }) {
        guard lifecycle == nil else { return }
        lifecycle = HostTerminationLifecycle(prepare: prepare, cleanup: cleanup)

        _ = Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleSIGTERM() }
        }
        source.resume()
        sigtermSource = source
    }

    /// True when macOS opened Farside as a login item rather than the person opening it.
    var onLaunch: ((Bool) -> Void)?
    var onReopen: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?(Self.launchedAsLoginItem)
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { onReopen?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle?.applicationWillTerminate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle?.shouldTerminate { sender.reply(toApplicationShouldTerminate: $0) } ?? .terminateNow
    }

    private func handleSIGTERM() {
        lifecycle?.requestTermination {
            NSApplication.shared.terminate(nil)
        }
    }
}
