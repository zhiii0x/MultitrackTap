import Foundation
import MultitrackCore

/// Thin metering decorator around a real `AudioTap`.
///
/// It forwards `start`/`stop`/`source`/`format` to the wrapped tap unchanged,
/// so it slots straight into `RecordingCoordinator` in place of the real tap.
/// On every chunk it (1) computes a peak level over the interleaved samples and
/// publishes it via `onLevel`, then (2) passes the chunk through to the
/// coordinator's callback untouched.
///
/// This keeps level metering entirely in the app layer — `MultitrackCore` is
/// not modified and stays unaware of metering.
final class MeteredTap: AudioTap {
    var source: Source { wrapped.source }
    var format: AudioFormat { wrapped.format }

    /// Called on every chunk with a peak level in 0...1. Invoked on the tap's
    /// own audio thread; the UI hop to the main actor happens in the closure
    /// supplied by the caller.
    ///
    /// Contract: set once before `start()` and treated as read-only during
    /// capture (set-before-start / read-only-during-capture). Do not reassign
    /// while the tap is running — there is no synchronization on this property.
    var onLevel: ((Float) -> Void)?

    private let wrapped: AudioTap

    // MARK: - Debug rate instrumentation (MT_DEBUG)
    private static let debugEnabled = ProcessInfo.processInfo.environment["MT_DEBUG"] != nil
    private var dbgFirstHostNanos: UInt64 = 0
    private var dbgLastHostNanos: UInt64 = 0
    private var dbgLastChunkFrames: Int = 0
    private var dbgTotalFrames: Int = 0

    init(wrapping tap: AudioTap) {
        self.wrapped = tap
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        // Reset debug fields before starting.
        dbgFirstHostNanos = 0
        dbgLastHostNanos = 0
        dbgLastChunkFrames = 0
        dbgTotalFrames = 0

        try wrapped.start { [weak self] chunk in
            if let self {
                self.onLevel?(Self.peak(of: chunk.samples))
                if Self.debugEnabled { self.dbgRecord(chunk) }
            }
            onChunk(chunk)
        }
    }

    func stop() {
        wrapped.stop()
        if Self.debugEnabled { dbgReport() }
        onLevel?(0)
    }

    // MARK: - Debug helpers

    private func dbgRecord(_ chunk: AudioChunk) {
        let channels = max(1, wrapped.format.channelCount)
        let frames = chunk.samples.count / channels
        guard frames > 0 else { return }
        if dbgFirstHostNanos == 0 { dbgFirstHostNanos = chunk.hostNanos }
        else { dbgTotalFrames += dbgLastChunkFrames }
        dbgLastHostNanos = chunk.hostNanos
        dbgLastChunkFrames = frames
    }

    private func dbgReport() {
        let declared = wrapped.format.sampleRate
        let name = wrapped.source.name
        guard dbgFirstHostNanos != 0, dbgLastHostNanos > dbgFirstHostNanos, dbgTotalFrames > 0 else {
            try? FileHandle.standardError.write(contentsOf: Data("[rate] \(name): declared \(declared) Hz — too few chunks to measure\n".utf8)); return
        }
        let spanSeconds = Double(dbgLastHostNanos - dbgFirstHostNanos) / 1_000_000_000.0
        let actual = Double(dbgTotalFrames) / spanSeconds
        let ratio = actual / declared
        let line = String(format: "[rate] %@: declared %.0f Hz, actual %.1f Hz (%.4f x, %+.2f%%) over %.2fs%@\n",
            name, declared, actual, ratio, (ratio - 1) * 100, spanSeconds, abs(ratio - 1) > 0.005 ? "  <-- MISMATCH" : "")
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    /// Peak absolute amplitude over interleaved float samples, clamped to 0...1.
    private static func peak(of samples: [Float]) -> Float {
        var maxAbs: Float = 0
        for sample in samples {
            let a = abs(sample)
            if a > maxAbs { maxAbs = a }
        }
        return min(maxAbs, 1)
    }
}
