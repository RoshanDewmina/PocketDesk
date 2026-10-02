import Foundation
import CoreMedia

/// The frame rate the host captures and sends at (Docs/perf/PLAN-120FPS-AND-LOAD.md §3).
/// A source of 100 Hz or more is streamed at 120 when `highRefreshCapture` is on; everything else,
/// including a display whose rate is unknown, stays at 60. The override exists for tests and for
/// forcing the 120 path on a 60 Hz panel (ScreenCaptureKit then still delivers at most 60).
enum CaptureRatePolicy {
    static let standardFPS = 60
    static let highFPS = 120
    static let highRefreshThresholdHz = 100.0
    static let overrideRange = 30...120
    static let intervalFollowsLadderDisabledKey = "farsideCaptureIntervalFollowsLadderDisabled"
    /// Frozen on first process use; tests inject the choice instead of mutating standard defaults.
    static let intervalFollowsLadderEnabled = resolveIntervalFollowsLadder()

    static func resolveIntervalFollowsLadder(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: intervalFollowsLadderDisabledKey)
    }

    /// Reduced rates throttle production even with native-rate tuning. At 60 and above the
    /// existing display-cadence policy is preserved, including the one-Hz high-refresh tolerance.
    static func minimumFrameInterval(for tuning: StreamTuning, targetFPS: Int, displayRefreshHz: Double?,
                                     followsLadder: Bool = intervalFollowsLadderEnabled) -> CMTime {
        if followsLadder, targetFPS > 0, targetFPS < standardFPS {
            return CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        }
        if targetFPS > standardFPS {
            if let displayRefreshHz, displayRefreshHz > Double(targetFPS) + 1 {
                return CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            }
            return .zero
        }
        return tuning.captureAtNativeRate ? .zero : CMTime(value: 1, timescale: 60)
    }

    static func targetFPS(displayRefreshHz: Double?, tuning: StreamTuning) -> Int {
        if let override = tuning.targetFPSOverride, overrideRange.contains(override) { return override }
        guard tuning.highRefreshCapture, let displayRefreshHz, displayRefreshHz >= highRefreshThresholdHz else {
            return standardFPS
        }
        return highFPS
    }

    /// Picture copy: 120 is promised only when the Mac reports a source of 100 Hz or more and, when it
    /// says so, a 120 fps capture target, and this phone presents at 100 Hz or more. Unknown reads as 60.
    static func pictureRateDescription(hostDisplayRefreshHz: Double?, hostTargetFPS: Int?, phoneDisplayFPS: Int?) -> String {
        guard let hostDisplayRefreshHz, hostDisplayRefreshHz.isFinite, hostDisplayRefreshHz >= highRefreshThresholdHz,
              (hostTargetFPS ?? highFPS) >= highFPS,
              let phoneDisplayFPS, Double(phoneDisplayFPS) >= highRefreshThresholdHz else { return "60 fps" }
        return "up to 120 fps on a 120 Hz Mac display"
    }

    /// ScreenCaptureKit's queue: five at 60 (the idle-refresh copy and the encoder each hold a
    /// surface), the header's maximum of eight above 60 so a burst does not drop frames.
    static func queueDepth(for fps: Int) -> Int {
        fps > standardFPS ? 8 : 5
    }

    /// The capture long edge: the mode's cap at this rate, reduced to the client's own longest
    /// screen edge when the client advertised it and the switch is on. Never raised above the cap.
    static func maximumDimension(quality: StreamQuality, fps: Int, clientLongEdge: Int?, tuning: StreamTuning) -> Int {
        let cap = quality.maximumDimension(at: fps)
        guard tuning.capToClientPixels, let clientLongEdge, clientLongEdge >= 640 else { return cap }
        return min(cap, clientLongEdge)
    }
}

/// A client's screen size in device pixels, sent on heartbeats so the host never encodes more
/// pixels than the phone can show.
struct PixelSize: Codable, Equatable {
    var width: Int
    var height: Int

    var longEdge: Int { max(width, height) }

    func validate() throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height) else { throw RemoteError.invalidMessage }
    }
}
