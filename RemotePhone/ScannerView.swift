import SwiftUI
import AVFoundation

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    var onUnavailable: () -> Void = {}
    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode: onCode, onUnavailable: onUnavailable)
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "PocketDesk.qr")
    private let onCode: (String) -> Bool
    private let onUnavailable: () -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    init(onCode: @escaping (String) -> Bool, onUnavailable: @escaping () -> Void) {
        self.onCode = onCode
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
        guard !done, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              (try? PairInvitation.parse(value)) != nil else { return }
        if onCode(value) { stop() }
    }
    func stop() { done = true; queue.async { [capture] in capture.stopRunning() } }
}
