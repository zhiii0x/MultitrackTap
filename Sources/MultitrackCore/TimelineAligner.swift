import Foundation

public enum TimelineAligner {
    /// Frames of leading silence to prepend to a stem so that a sample which
    /// arrived at `firstSampleHostNanos` lines up with recording start
    /// `startHostNanos`. Clamps to 0 for samples at/before start.
    public static func leadingSilenceFrames(startHostNanos: UInt64,
                                            firstSampleHostNanos: UInt64,
                                            sampleRate: Double) -> Int {
        guard firstSampleHostNanos > startHostNanos else { return 0 }
        let deltaSeconds = Double(firstSampleHostNanos - startHostNanos) / 1_000_000_000.0
        return Int((deltaSeconds * sampleRate).rounded())
    }
}
