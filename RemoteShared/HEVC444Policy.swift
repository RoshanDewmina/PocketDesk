import Foundation

/// Format evidence only. No cadence, text quality, thermal or device acceptance follows.
struct HEVC444SPS: Equatable {
    let tier: UInt8
    let level: UInt8
    let width: Int
    let height: Int
    let displayWidth: Int
    let displayHeight: Int

    static func parse(_ nal: Data) -> HEVC444SPS? {
        guard nal.count >= 18, nal.count <= 65536, nal[0] == 0x42, nal[1] == 1 else { return nil }
        var bytes: [UInt8] = [], zeros = 0
        let input = Array(nal.dropFirst(2))
        for i in input.indices {
            let byte = input[i]
            if zeros >= 2, byte == 3 {
                guard i + 1 < input.count, input[i + 1] <= 3 else { return nil }
                zeros = 0; continue
            }
            guard zeros < 2 || byte > 2 else { return nil }
            bytes.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        var bits = HEVC444Bits(bytes: bytes)
        guard bits.read(4) != nil, bits.read(3) == 0, bits.read(1) == 1, // Single temporal layer.
              bits.read(2) == 0, let tier = bits.read(1), bits.read(5) == 4,
              bits.read(32) == 0x08000000,
              // Progressive, non-packed, frame-only Main 4:4:4 8, no alternate RExt/HDR constraint set.
              bits.read(48) == 0xbe0800000000,
              let level = bits.read(8), [30, 60, 63, 90, 93, 120, 123, 150, 153].contains(level),
              let spsID = bits.ue(), spsID <= 15, bits.ue() == 3, bits.read(1) == 0,
              let width = bits.ue(), let height = bits.ue(), width > 0, height > 0,
              width <= 4096, height <= 4096, let crop = bits.read(1) else { return nil }
        var displayWidth = width, displayHeight = height
        if crop == 1 {
            guard let left = bits.ue(), let right = bits.ue(), let top = bits.ue(), let bottom = bits.ue(),
                  left + right < width, top + bottom < height else { return nil }
            displayWidth -= left + right; displayHeight -= top + bottom
        }
        guard bits.ue() == 0, bits.ue() == 0 else { return nil } // Exactly 8-bit luma/chroma.
        return HEVC444SPS(tier: UInt8(tier), level: UInt8(level), width: Int(width), height: Int(height), displayWidth: Int(displayWidth), displayHeight: Int(displayHeight))
    }
}
private struct HEVC444Bits {
    let bytes: [UInt8]
    private var offset = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    mutating func read(_ count: Int) -> UInt64? {
        guard count >= 0, count <= 64, offset <= bytes.count * 8 - count else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count { value = (value << 1) | UInt64((bytes[offset / 8] >> (7 - offset % 8)) & 1); offset += 1 }
        return value
    }
    mutating func ue() -> UInt64? {
        var count = 0
        while true {
            guard let bit = read(1) else { return nil }
            if bit == 1 { break }
            count += 1; guard count <= 16 else { return nil }
        }
        guard let tail = read(count) else { return nil }
        return (UInt64(1) << count) - 1 + tail
    }
}

enum HEVC444Policy {
    static let preferenceKey = "farsideExperimentalFullColorHEVC444"
    /// The physical .8 Main444 path received frames but never decoded them on iPhone 17.
    /// Keep it out of normal launches and distribution until that path passes acceptance.
    /// A development-only argument permits an explicit fallback regression run.
    static var enabled: Bool { isEnabled() }
    static func isEnabled(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--farside-full-color-recovery-check")
            && defaults.bool(forKey: preferenceKey)
        #else
        return false
        #endif
    }
    /// The profile is obtained from the public session catalog, never a blind private/exportless constant.
    static func catalogProfile(_ values: [String]) -> String? { values.first { $0 == "HEVC_Main444_AutoLevel" } }
    static func permits(preference: Bool, simulator: Bool, disabled: Bool, decoder: Bool, encoder: Bool, isHost: Bool) -> Bool {
        preference && !simulator && !disabled && decoder && (!isHost || encoder)
    }
    /// Full color wins: lossless still-text refinement never runs beside a 4:4:4 session.
    static func permitsRefinement(requested: Bool, fullColor: Bool) -> Bool { requested && !fullColor }
    static func cacheKey(role: String, systemAndModel: String) -> String? {
        guard ["encode", "decode"].contains(role), !systemAndModel.isEmpty, !systemAndModel.contains("unknown") else { return nil }
        return "Farside.HEVC.Main444.8bit.probe.v1.RTC153." + role + "." + systemAndModel
    }
}
