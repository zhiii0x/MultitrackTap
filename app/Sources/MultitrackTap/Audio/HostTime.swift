import Foundation
import Darwin

/// Single source of truth for converting mach host-time ticks to nanoseconds.
///
/// CRITICAL: every timestamp fed into MultitrackCore's
/// `RecordingCoordinator` / `TimelineAligner` MUST come through here so the mic
/// tap, the process tap, and the recording start all share one nanosecond
/// timebase. If they don't, leading-silence padding is computed against the
/// wrong clock and the stems will not line up.
///
/// `mach_absolute_time()`, `AVAudioTime.hostTime`, and the Core Audio IOProc's
/// `inNow`/`inInputTime` (`AudioTimeStamp.mHostTime`) are all expressed in the
/// SAME host-time tick units, so this one conversion is valid for all of them.
enum HostTime {
    /// mach_timebase_info: nanoseconds = ticks * numer / denom.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts mach host-time ticks to nanoseconds.
    static func nanos(fromHostTime hostTime: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return hostTime } // common Apple Silicon case (1/1)
        // Use 128-bit-ish widening via two 64-bit halves to avoid overflow on
        // long-running captures.
        let high = hostTime / denom
        let low = hostTime % denom
        return high * numer + (low * numer) / denom
    }

    /// Convenience: current host time, already in nanoseconds.
    static func nowNanos() -> UInt64 {
        nanos(fromHostTime: mach_absolute_time())
    }
}
