import Foundation

/// Phone video viewport points, excluding chrome. Validation is required after wire decoding.
struct VirtualDisplayViewport: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
    let scale: Double
    let maximumFPS: Int
    var iPadWorkspace: Bool? = nil

    /// Invalid/nonintegral/odd requests have no representable backing dimension. Never round
    /// down a phone's raster to make a mode or encoder accept it.
    var pixelWidth: Int { Self.exactEvenPixels(width, scale: scale) }
    var pixelHeight: Int { Self.exactEvenPixels(height, scale: scale) }

    func validate() throws {
        guard width.isFinite, height.isFinite, scale.isFinite,
              (64...4096).contains(width), (64...4096).contains(height),
              (1...3).contains(scale), (60...120).contains(maximumFPS),
              pixelWidth >= 128, pixelHeight >= 128,
              pixelWidth * pixelHeight <= VirtualDisplaySpecification.maximumPixels else {
            throw SessionVirtualDisplayPolicyError.unsupportedViewport
        }
    }

    private static func exactEvenPixels(_ points: Double, scale: Double) -> Int {
        let pixels = points * scale
        guard pixels.isFinite, pixels >= 128, pixels <= Double(VirtualDisplaySpecification.maximumAxisPixels),
              pixels == pixels.rounded(), pixels.truncatingRemainder(dividingBy: 2) == 0 else { return 0 }
        return Int(pixels)
    }
}

enum SessionVirtualDisplayPolicyError: Error { case unsupportedViewport }

struct VirtualDisplaySpecification: Equatable, Sendable {
    static let maximumAxisPixels = 7680
    static let maximumPixels = 16_777_216
    let width: Int
    let height: Int
    let refreshHz: Int
    var logicalWidth: Int { width / 2 }
    var logicalHeight: Int { height / 2 }
    var at60Hz: VirtualDisplaySpecification { Self(width: width, height: height, refreshHz: 60) }

    private init(width: Int, height: Int, refreshHz: Int) {
        self.width = width; self.height = height; self.refreshHz = refreshHz
    }

    init?(viewport: VirtualDisplayViewport) {
        guard (try? viewport.validate()) != nil else { return nil }
        width = viewport.pixelWidth
        height = viewport.pixelHeight
        refreshHz = viewport.maximumFPS == 120 ? 120 : 60
    }

    func matches(logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double) -> Bool {
        logicalWidth == self.logicalWidth && logicalHeight == self.logicalHeight
            && pixelWidth == width && pixelHeight == height
            && refreshHz.isFinite && abs(refreshHz - Double(self.refreshHz)) < 0.5
    }

    struct AdvertisedMode: Hashable, Sendable {
        let width: Int
        let height: Int
        let refreshHz: Int
    }
    /// Requested raster anchor first, requested logical mode second. Common landscape modes
    /// give WindowServer enough EDID-like context to expose HiDPI, as in the reviewed spike.
    var advertisedModes: [AdvertisedMode] {
        let pairs = [(width, height), (logicalWidth, logicalHeight), (3840, 2160), (1920, 1080),
                     (2560, 1440), (1280, 720), (1920, 1200), (960, 600)]
        var seen = Set<AdvertisedMode>()
        return pairs.compactMap { pair in
            let mode = AdvertisedMode(width: pair.0, height: pair.1, refreshHz: refreshHz)
            return seen.insert(mode).inserted ? mode : nil
        }
    }
}

enum SessionVirtualDisplayOwnership {
    static func permitsModeChange(requestedID: UInt32, retainedID: UInt32, online: Bool,
                                  identityMatches: Bool, isMain: Bool, isMirrored: Bool) -> Bool {
        requestedID != 0 && requestedID == retainedID && online && identityMatches && !isMain && !isMirrored
    }
}

/// Fixed framing rejects plain background pixels as a content-cadence measurement.
enum SessionVirtualDisplayBarcode {
    static let bits = 24
    static func white(slot: Int, frame: UInt32) -> Bool {
        slot < 0 ? slot.isMultiple(of: 2) : (frame & (1 << UInt32(slot))) != 0
    }
    static func decode(read: (Int) -> Bool?) -> UInt32? {
        for slot in -4..<0 {
            guard read(slot) == slot.isMultiple(of: 2) else { return nil }
        }
        var frame: UInt32 = 0
        for slot in 0..<bits {
            guard let white = read(slot) else { return nil }
            if white { frame |= 1 << UInt32(slot) }
        }
        return frame
    }
}
