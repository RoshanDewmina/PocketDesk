import SwiftUI
import AVFoundation

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(onCode: onCode) }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "PocketDesk.qr")
    private let onCode: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
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
    private func showPermissionHelp() {
        let label = UILabel(); label.text = "Camera access is needed to scan. Enable Camera for PocketDesk in Settings, or dismiss and paste the code."; label.numberOfLines = 0; label.textColor = .white; label.textAlignment = .center; label.frame = view.bounds.insetBy(dx: 24, dy: 100); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value.hasPrefix("pocketdesk:") else { return }
        done = true; stop(); onCode(value)
    }
    func stop() { done = true; queue.async { [capture] in capture.stopRunning() } }
}
