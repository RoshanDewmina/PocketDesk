import Foundation

/// A modelled data-use range for one picture preset, from a mostly static screen to sustained motion at
/// the encoder ceiling. Payload rates only: carrier billing adds IP/UDP and retransmission overhead.
/// Files and guest viewers are separate traffic and never part of this range.
struct DataUseEstimate: Equatable {
    /// libwebrtc's default Opus rate for a mono track (32 kb/s) plus per-packet RTP/SRTP headers at
    /// 50 packets a second, rounded up. The Mac track sets no bitrate of its own.
    static let macAudioKbps = 64.0
    /// Upper bound for relay packet repair (FlexFEC), the 20 % Sunshine ships as its default.
    static let packetRepairOverhead = 0.2

    let lowKbps: Double
    let highKbps: Double

    init(videoKbps: ClosedRange<Double>, audioKbps: Double = 0, repairOverhead: Double = 0) {
        let repair = 1 + max(0, repairOverhead)
        let audio = max(0, audioKbps)
        lowKbps = max(0, videoKbps.lowerBound) * repair + audio
        highKbps = max(0, videoKbps.upperBound) * repair + audio
    }

    init(_ quality: StreamQuality, audio: Bool, packetRepair: Bool) {
        self.init(videoKbps: quality.staticKbps...Double(quality.maximumBitrateBps) / 1000,
                  audioKbps: audio ? Self.macAudioKbps : 0,
                  repairOverhead: packetRepair ? Self.packetRepairOverhead : 0)
    }

    /// Decimal gigabytes: kb/s × 3600 s ÷ 8 bits ÷ 10⁶ kB per GB. 25,000 kb/s is 11.25 GB an hour.
    static func gigabytesPerHour(kbps: Double) -> Double { max(0, kbps) * 3600 / 8 / 1_000_000 }

    var lowGBPerHour: Double { Self.gigabytesPerHour(kbps: lowKbps) }
    var highGBPerHour: Double { Self.gigabytesPerHour(kbps: highKbps) }

    /// Rounded for reading, never down to zero: one decimal below 10 GB, whole numbers above.
    static func display(_ gigabytes: Double, locale: Locale = .current) -> String {
        let rounded = gigabytes >= 10 ? gigabytes.rounded() : max(0.1, (gigabytes * 10).rounded() / 10)
        return rounded.formatted(.number.precision(.fractionLength(gigabytes >= 10 ? 0...0 : 0...1)).locale(locale))
    }
}

extension StreamQuality {
    /// Modelled, not measured: a still desktop with a blinking caret or clock sends small delta frames
    /// and RTCP. Kept above zero so a static screen is never shown as free.
    var staticKbps: Double { self == .sharp ? 400 : 200 }
}
