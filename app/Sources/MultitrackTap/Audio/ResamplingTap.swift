import Foundation
@preconcurrency import AVFoundation
import MultitrackCore

/// Sample-rate-conversion decorator around any `AudioTap`.
///
/// Different taps deliver different native sample rates — a Bluetooth mic may
/// run at 24 kHz or 44.1 kHz, while the app/system process taps run at 48 kHz.
/// For a clean multitrack project every stem must share one rate. This decorator
/// resamples each incoming chunk from the wrapped tap's native rate to `target`
/// (48 kHz) using `AVAudioConverter`, so all stems line up at the project rate.
///
/// Channel count is PRESERVED (a mono source stays mono; no upmix to stereo).
/// Each forwarded chunk keeps the SAME `hostNanos` as the source chunk: the
/// chunk's start time is unchanged, only the samples between start times are
/// resampled. `RecordingCoordinator`'s leading-silence alignment uses the first
/// chunk's `hostNanos` together with the (target) sample rate, so alignment is
/// preserved.
///
/// Runs entirely on the wrapped tap's audio thread — no main-actor access here.
final class ResamplingTap: AudioTap {
    let source: Source
    let format: AudioFormat

    private let wrapped: AudioTap
    private let target: Double

    // AVAudioConverter and its input/output AVAudioFormats are created lazily on
    // first chunk (and reused), all on the audio thread.
    private var converter: AVAudioConverter?
    private let inputAVFormat: AVAudioFormat
    private let outputAVFormat: AVAudioFormat
    private let channelCount: Int

    /// Wraps `tap`, resampling its output to `target` Hz while preserving channel
    /// count. Callers should only wrap taps whose native rate differs from the
    /// target; a same-rate wrap still works but is wasted work.
    init(wrapping tap: AudioTap, target: Double) {
        self.wrapped = tap
        self.target = target
        let channels = max(1, tap.format.channelCount)
        self.channelCount = channels
        self.source = tap.source
        self.format = AudioFormat(sampleRate: target, channelCount: channels)

        // Interleaved 32-bit float, matching the [Float] chunk layout used
        // throughout the app, at the wrapped (input) and target (output) rates.
        self.inputAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tap.format.sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true)!
        self.outputAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: target,
            channels: AVAudioChannelCount(channels),
            interleaved: true)!
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        // Build the converter once up front. AVAudioConverter is created on the
        // start thread and only used from the wrapped tap's audio thread after.
        guard let converter = AVAudioConverter(from: inputAVFormat, to: outputAVFormat) else {
            throw NSError(
                domain: "MultitrackTap.ResamplingTap", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't create AVAudioConverter \(inputAVFormat.sampleRate)→\(target) Hz"])
        }
        self.converter = converter

        try wrapped.start { [weak self] chunk in
            guard let self else { return }
            if let resampled = self.resample(chunk) {
                onChunk(resampled)
            }
        }
    }

    func stop() {
        wrapped.stop()
        converter = nil
    }

    /// Converts one interleaved-float chunk from the input rate to the target
    /// rate, preserving channel count and `hostNanos`. Returns nil if there are
    /// no input frames or the conversion produced no output.
    private func resample(_ chunk: AudioChunk) -> AudioChunk? {
        guard let converter else { return nil }

        let inFrameCount = chunk.samples.count / channelCount
        guard inFrameCount > 0 else { return nil }

        // Build the input buffer from the chunk's interleaved samples.
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inputAVFormat,
            frameCapacity: AVAudioFrameCount(inFrameCount)) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(inFrameCount)
        guard let inChannelData = inBuffer.floatChannelData else { return nil }
        chunk.samples.withUnsafeBufferPointer { src in
            // Interleaved float: a single packed channel-0 pointer of
            // frameCount * channelCount floats.
            inChannelData[0].update(from: src.baseAddress!, count: chunk.samples.count)
        }

        // Size the output buffer for the resampled frame count, rounded up with a
        // little slack so the converter never truncates due to fractional ratios.
        let ratio = target / inputAVFormat.sampleRate
        let estimatedOutFrames = Int((Double(inFrameCount) * ratio).rounded(.up)) + 8
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outputAVFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutFrames)) else { return nil }

        // The converter pulls input via this block. AVAudioConverter may consume
        // and emit different frame counts (it buffers internally for SRC), so we
        // hand it the whole chunk on the first pull and report end-of-stream on
        // any subsequent pull within this conversion call. The input block is
        // `@Sendable`, but it runs synchronously on this same thread during
        // `convert`, so a reference-box flag is safe here.
        let supplied = SuppliedFlag()
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if supplied.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        guard status != .error, conversionError == nil else { return nil }

        let outFrames = Int(outBuffer.frameLength)
        guard outFrames > 0, let outChannelData = outBuffer.floatChannelData else { return nil }

        // Read back interleaved floats (frameLength * channelCount).
        let sampleCount = outFrames * channelCount
        let outSamples = Array(UnsafeBufferPointer(start: outChannelData[0], count: sampleCount))
        return AudioChunk(hostNanos: chunk.hostNanos, samples: outSamples)
    }
}

/// One-shot "already supplied input" flag for the synchronous
/// `AVAudioConverterInputBlock`. The block is `@Sendable`, but it's invoked
/// inline on the calling thread during `convert`, so this single-threaded
/// mutation is safe — `nonisolated(unsafe)` tells the compiler we've checked.
private final class SuppliedFlag: @unchecked Sendable {
    var value = false
}
