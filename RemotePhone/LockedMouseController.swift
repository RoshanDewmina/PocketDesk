import SwiftUI
import UIKit

/// Public presented controller owns UIKit's lock preference. overFullScreen keeps the
/// live desktop visible beneath the transparent input layer; no hosting-class swizzle.
struct LockedMousePresenter: UIViewControllerRepresentable {
    @Binding var requested: Bool
    let eligible: Bool
    let revision: UInt64
    let gain: Double
    let remapShortcuts: Bool
    let send: (NativeGestureCommand) -> Bool
    let key: (String, [String]) -> Bool
    let modifiers: ([String]) -> Void
    let cleanup: () -> Void
    let ended: (String) -> Void
    func makeUIViewController(context: Context) -> LockedMousePresentationAnchor { LockedMousePresentationAnchor() }
    func updateUIViewController(_ anchor: LockedMousePresentationAnchor, context: Context) {
        anchor.update(requested: requested, eligible: eligible, revision: revision, gain: gain, remapShortcuts: remapShortcuts,
            send: send, key: key, modifiers: modifiers, cleanup: cleanup) { message in requested = false; ended(message) }
    }
    static func dismantleUIViewController(_ anchor: LockedMousePresentationAnchor, coordinator: ()) { anchor.stop() }
}

final class LockedMousePresentationAnchor: UIViewController {
    private var lockController: LockedMouseController?
    private var presentation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pendingRevision: UInt64?
    private var lastEnded: ((String) -> Void)?
    private var blockedUntilRequestReset = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    func update(requested: Bool, eligible: Bool, revision: UInt64, gain: Double, remapShortcuts: Bool,
                send: @escaping (NativeGestureCommand) -> Bool, key: @escaping (String, [String]) -> Bool,
                modifiers: @escaping ([String]) -> Void, cleanup: @escaping () -> Void, ended: @escaping (String) -> Void) {
        lastEnded = ended
        if !requested { blockedUntilRequestReset = false }
        if presentation != nil && (!requested || !eligible || pendingRevision != revision) { stop(); return }
        if let controller = lockController {
            controller.gain = gain
            controller.remapShortcuts = remapShortcuts
            if !requested || !eligible || controller.revision != revision { stop() }
            return
        }
        guard requested, eligible, !blockedUntilRequestReset, presentation == nil else { return }
        generation &+= 1; let ticket = generation; pendingRevision = revision
        presentation = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                if let window = self.view.window, let root = window.rootViewController,
                   root.presentedViewController == nil, window.windowScene?.activationState == .foregroundActive {
                    let controller = LockedMouseController(revision: revision, gain: gain, remapShortcuts: remapShortcuts, send: send, key: key, modifiers: modifiers, cleanup: cleanup)
                    controller.onEnded = { [weak self, weak controller] message in
                        guard let self, self.lockController === controller else { return }
                        self.lockController = nil; self.presentation = nil; self.blockedUntilRequestReset = true
                        let completionGeneration = self.generation
                        DispatchQueue.main.async { [weak self] in
                            guard self?.generation == completionGeneration else { return }
                            ended(message)
                        }
                    }
                    self.lockController = controller; self.presentation = nil; self.pendingRevision = nil
                    controller.modalPresentationStyle = .overFullScreen; controller.isModalInPresentation = true
                    root.present(controller, animated: false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            self.presentation = nil; self.pendingRevision = nil; self.blockedUntilRequestReset = true; ended("Mouse lock is unavailable here. Keep using the normal pointer.")
        }
    }
    func stop() {
        let hadPending = presentation != nil
        generation &+= 1; presentation?.cancel(); presentation = nil; pendingRevision = nil
        if hadPending, let lastEnded {
            blockedUntilRequestReset = true; let completionGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == completionGeneration else { return }
                lastEnded("Mouse lock cancelled because the session changed.")
            }
        }
        lockController?.finish("Mouse unlocked. Normal pointer restored.")
        lockController = nil
    }
}

final class LockedMouseController: UIViewController {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    let revision: UInt64
    var gain: Double
    var remapShortcuts: Bool
    var onEnded: ((String) -> Void)?
    private let router = LockedRelativeMouseRouter()
    private let input = NativeTrackpadInputView()
    private let caption = UILabel()
    private var generation: UInt64 = 0
    private var wantsLock = true
    private var finished = false
    private var everLocked = false
    private var refusal: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let keySend: (String, [String]) -> Bool
    private let modifierSend: ([String]) -> Void
    private let cleanup: () -> Void
    init(revision: UInt64, gain: Double, remapShortcuts: Bool = true, send: @escaping (NativeGestureCommand) -> Bool,
         key: @escaping (String, [String]) -> Bool, modifiers: @escaping ([String]) -> Void, cleanup: @escaping () -> Void = {}) {
        self.revision = revision; self.gain = gain; self.remapShortcuts = remapShortcuts; self.keySend = key; self.modifierSend = modifiers; self.cleanup = cleanup
        super.init(nibName: nil, bundle: nil)
        router.send = send
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersPointerLocked: Bool { wantsLock && !finished }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .clear
        input.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(input)
        NSLayoutConstraint.activate([input.leadingAnchor.constraint(equalTo: view.leadingAnchor), input.trailingAnchor.constraint(equalTo: view.trailingAnchor), input.topAnchor.constraint(equalTo: view.topAnchor), input.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        input.keyboard.remapEnabled = { [weak self] in self?.remapShortcuts == true }
        input.hardwareKeys = true; input.keyboard.send = keySend; input.keyboard.modifiersChanged = modifierSend
        // No absolute mouse/finger router while the lock layer owns input. Scroll remains phased.
        input.pointer.onCommand = { [weak self] command in
            guard let self, self.actualLock else { return false }
            switch command { case .scroll: return self.router.hold == nil && self.router.send(command); case .zoom, .zoomEnded: return self.router.send(command); default: return false }
        }
        let unlock = UIButton(type: .system); unlock.setTitle("Unlock mouse", for: .normal)
        unlock.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
        unlock.accessibilityIdentifier = "remote.mouse.unlock"
        caption.text = "Requesting mouse lock…"; caption.font = .preferredFont(forTextStyle: .footnote); caption.textColor = .white
        let bar = UIStackView(arrangedSubviews: [caption, unlock]); bar.spacing = 16; bar.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        bar.isLayoutMarginsRelativeArrangement = true; bar.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(bar)
        NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), bar.centerXAnchor.constraint(equalTo: view.centerXAnchor), bar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8), bar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8)])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene,
                      scene === self.view.window?.windowScene else { return }
                self.refreshLock()
            }
        })
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish("Mouse unlocked while Farside was inactive.") }
            })
        }
    }
    private var actualLock: Bool {
        !finished && wantsLock && view.window?.windowScene?.activationState == .foregroundActive && view.window?.windowScene?.pointerLockState?.isLocked == true
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        generation = HardwarePeripherals.shared.claimLockedMouse(owner: self, gate: { [weak self] in self?.actualLock == true },
            move: { [weak self] x, y in guard let self else { return }; self.router.move(x: x, y: y, gain: self.gain) },
            button: { [weak self] name, down in self?.button(name, down: down) },
            lost: { [weak self] in self?.finish("Mouse disconnected or another session took control.") },
            keyboardOwner: input, keyboardDisconnect: { [weak self] in self?.input.keyboard.releaseAll() })
        input.setKeyboardFocus(true); setNeedsUpdateOfPrefersPointerLocked(); refreshLock()
        refusal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.actualLock else { return }
            self.finish("iPadOS did not grant mouse lock. Use a fullscreen foreground session, or the normal pointer.")
        }
    }
    private func refreshLock() {
        let locked = actualLock
        router.setEnabled(locked); input.pointer.setEnabled(locked)
        if locked { everLocked = true; caption.text = "Relative mouse locked · touch Unlock to leave" }
        else if everLocked { finish("Mouse lock ended. Normal pointer restored.") }
    }
    private func button(_ name: String, down: Bool) {
        guard actualLock else { return }
        if name == "primary" { router.primary(down); return }
        guard !down, router.hold == nil else { return }
        if name == "secondary" { _ = router.send(.secondaryClick) }
        else if name == "middle" { _ = router.send(.middleClick) }
        else if let button = AuxiliaryMouseButton(rawValue: name) { _ = router.send(.auxiliaryClick(button)) }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        finish("Mouse unlocked for the window or orientation change."); super.viewWillTransition(to: size, with: coordinator)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); finish("Mouse unlocked.") }
    @objc private func unlockTapped() { finish("Mouse unlocked. Normal pointer restored.") }
    func finish(_ message: String) {
        guard !finished else { return }
        finished = true; wantsLock = false; refusal?.cancel(); refusal = nil
        router.setEnabled(false); input.pointer.setEnabled(false); input.hardwareKeys = false; input.setKeyboardFocus(false); input.keyboard.releaseAll()
        // Cleanup belongs to this owner transition, before another scene can claim.
        cleanup()
        HardwarePeripherals.shared.releaseLockedMouse(owner: self, generation: generation)
        setNeedsUpdateOfPrefersPointerLocked()
        dismiss(animated: false)
        onEnded?(message)
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
