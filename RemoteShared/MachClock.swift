import Foundation
import QuartzCore

/// Milliseconds on the mach_absolute_time clock: the timebase shared by CACurrentMediaTime,
/// CADisplayLink timestamps, MTLDrawable.presentedTime and ScreenCaptureKit's displayTime.
/// The bench marker, the host's clock echo and the phone's presented-frame times all use it, so a
/// single Cristian offset relates the two devices.
enum MachClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    static func milliseconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1_000_000
    }

    static func nowMs() -> Double {
        milliseconds(fromMachTicks: mach_absolute_time())
    }

    static func milliseconds(fromMediaTime seconds: CFTimeInterval) -> Double {
        seconds * 1000
    }
}
