import SwiftUI
import AVFoundation

/// Why a scanned or pasted code was not accepted, for feedback only. Acceptance itself is
/// always `PairInvitation.parse`; this never admits a code.
enum PairingCodeProblem: Equatable {
    case notFarside, expired, damaged

    init(code: String, now: Date = Date()) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("pocketdesk:") else { self = .notFarside; return }
        guard let data = Data(base64Encoded: String(text.dropFirst("pocketdesk:".count))),
              let invitation = try? JSONDecoder().decode(PairInvitation.self, from: data) else {
            self = .damaged
            return
        }
        self = invitation.expires <= now ? .expired : .damaged
    }

    var message: String {
        switch self {
        case .notFarside: "That isn’t a Farside pairing code."
        case .expired: "That code has expired. On your Mac, open Farside and make a new one."
        case .damaged: "That code didn’t read cleanly. Make a new one on your Mac and try again."
        }
    }
}

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    var onRejected: (PairingCodeProblem) -> Void = { _ in }
    var onUnavailable: () -> Void = {}
    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode: onCode, onRejected: onRejected, onUnavailable: onUnavailable)
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "PocketDesk.qr")
    private let onCode: (String) -> Bool
    private let onRejected: (PairingCodeProblem) -> Void
    private let onUnavailable: () -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    private var lastRejected: (code: String, at: TimeInterval)?
    init(onCode: @escaping (String) -> Bool, onRejected: @escaping (PairingCodeProblem) -> Void,
         onUnavailable: @escaping () -> Void) {
        self.onCode = onCode
        self.onRejected = onRejected
        self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async { if granted { self?.configure() } else { self?.showPermissionHelp() } }
        }
    }
    private func configure() {
        guard !done, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { showPermissionHelp(); return }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput(); guard capture.canAddOutput(output) else { showPermissionHelp(); return }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer; layer.frame = view.bounds
        queue.async { [capture] in capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    private func showPermissionHelp() { onUnavailable() }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        guard (try? PairInvitation.parse(value)) != nil else {
            // A code stays in view for many frames; say what is wrong once, not on every frame.
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastRejected, last.code == value, now - last.at < 3 { return }
            lastRejected = (value, now)
            onRejected(PairingCodeProblem(code: value))
            return
        }
        if onCode(value) { stop() }
    }
    func stop() { done = true; queue.async { [capture] in capture.stopRunning() } }
}
