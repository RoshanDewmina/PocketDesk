import XCTest
@testable import PocketDeskRemote

final class FrozenTextSnapshotTests: XCTestCase {
    func testCancelledPublicationCannotAdmitAnotherVisionJobUntilWorkFinishes() {
        let gate = FrozenTextWorkGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isBusy)
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertTrue(gate.begin())
        gate.finish()
    }
    func testNextReceiptRejectsChangedUnknownOrStaleTransportPlacement() throws {
        let placement = CGRect(x: 50, y: 0, width: 400, height: 200)
        let visible = CGRect(x: 100, y: 50, width: 200, height: 100)
        var region = CaptureRegion(epoch: 3, x: 50, y: 0, width: 400, height: 200, outputWidth: 800, outputHeight: 400)
        XCTAssertEqual(FrozenTextSnapshot.presentedCrop(visible: visible, expectedPlacement: placement, region: region, geometryCurrent: true, requiresRegion: true), CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        region.x = 75
        XCTAssertNil(FrozenTextSnapshot.presentedCrop(visible: visible, expectedPlacement: placement, region: region, geometryCurrent: true, requiresRegion: true))
        region.x = 50
        XCTAssertNil(FrozenTextSnapshot.presentedCrop(visible: visible, expectedPlacement: placement, region: region, geometryCurrent: false, requiresRegion: true))
        XCTAssertNil(FrozenTextSnapshot.presentedCrop(visible: visible, expectedPlacement: placement, region: nil, geometryCurrent: true, requiresRegion: true))
        XCTAssertNotNil(FrozenTextSnapshot.presentedCrop(visible: visible, expectedPlacement: placement, region: nil, geometryCurrent: true, requiresRegion: false))
    }
    func testCropIncludesOnlyVisiblePlacementWithNonzeroOrigin() throws {
        let crop = try XCTUnwrap(FrozenTextSnapshot.normalizedCrop(visible: CGRect(x: 100, y: 50, width: 200, height: 100),
            placement: CGRect(x: 50, y: 0, width: 400, height: 200)))
        XCTAssertEqual(crop, CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertNil(FrozenTextSnapshot.normalizedCrop(visible: .zero, placement: .zero))
        XCTAssertNil(FrozenTextSnapshot.normalizedCrop(visible: CGRect(x: 1000, y: 0, width: 50, height: 50),
            placement: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }
}

import UIKit
import WebRTC

extension FrozenTextSnapshotTests {
    func testSnapshotOwnsPixelsAndAppliesRotationBeforeVisibleCrop() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetBytesPerRow(pixels)*4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._90, timeStampNs: 1)
        let snapshot = try XCTUnwrap(FrozenTextSnapshot.copy(frame, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(snapshot.width, 2); XCTAssertEqual(snapshot.height, 8)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetBytesPerRow(pixels)*4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let data = try XCTUnwrap(snapshot.dataProvider?.data) as Data
        XCTAssertGreaterThan(try XCTUnwrap(data.first), 230, "Owned snapshot cannot read a reused decoder buffer")
        XCTAssertNil(FrozenTextSnapshot.copy(frame, crop: CGRect(x: -0.1, y: 0, width: 1, height: 1)))
    }
    @MainActor
    func testLocalOCRPreservesUsefulCodeTokens() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 700, height: 100))
            ("echo $HOME; exit 0" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .regular), .foregroundColor: UIColor.black])
        }
        let text = try FrozenTextSnapshot.recognize(XCTUnwrap(image.cgImage))
        XCTAssertTrue(text.contains("echo")); XCTAssertTrue(text.contains("$HOME")); XCTAssertTrue(text.contains("exit 0"))
    }
}
