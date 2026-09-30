import CoreGraphics
import Foundation

struct VideoPixelGeometry: Equatable {
    let bufferSize: CGSize
    let crop: CGRect
    let rotation: Int
    init?(bufferSize: CGSize, crop: CGRect, rotation: Int) {
        guard bufferSize.width > 0, bufferSize.height > 0,
              bufferSize.width <= 8192, bufferSize.height <= 8192,
              [0, 90, 180, 270].contains(rotation),
              [crop.minX, crop.minY, crop.width, crop.height].allSatisfy({ $0.isFinite && $0.rounded() == $0 }),
              crop.width > 0, crop.height > 0,
              CGRect(origin: .zero, size: bufferSize).contains(crop) else { return nil }
        self.bufferSize = bufferSize; self.crop = crop; self.rotation = rotation
    }
    var displaySize: CGSize { rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width) }
    /// Normalized top-left picture UV to original buffer UV, inverse of clockwise display rotation.
    func bufferUV(x: CGFloat, y: CGFloat) -> CGPoint {
        let point: CGPoint
        switch rotation {
        case 90: point = CGPoint(x: y, y: 1 - x)
        case 180: point = CGPoint(x: 1 - x, y: 1 - y)
        case 270: point = CGPoint(x: 1 - y, y: x)
        default: point = CGPoint(x: x, y: y)
        }
        return CGPoint(x: (crop.minX + point.x * crop.width) / bufferSize.width,
                       y: (crop.minY + point.y * crop.height) / bufferSize.height)
    }
}
