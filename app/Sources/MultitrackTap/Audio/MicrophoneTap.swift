import Foundation
import AVFoundation
import MultitrackCore

/// Captures the default input device (microphone) via `AVAudioEngine` and
/// delivers interleaved `[Float]` chunks stamped with host-time nanoseconds,
/// using the SAME timebase as the process tap and the recording start.
///
/// The reported `format` is read from the input hardware (sample rate + channel
/// count), never hardcoded.
final class MicrophoneTap: AudioTap {
    let source: Source
    let format: AudioFormat

    private let engine = AVAudioEngine()
    private let inputFormat: AVAudioFormat
    private var onChunk: ((AudioChunk) -> Void)?
    private var installed = false

    init() {
        // Read the TRUE hardware input format. inputNode.inputFormat(forBus:)
        // reflects the current input device's sample rate and channel count.
        let node = engine.inputNode
        let hwFormat = node.inputFormat(forBus: 0)
        self.inputFormat = hwFormat
        self.format = AudioFormat(
            sampleRate: hwFormat.sampleRate,
            channelCount: Int(hwFormat.channelCount)
        )
        self.source = Source(id: "microphone", name: "Microphone", kind: .microphone)
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        self.onChunk = onChunk

        let node = engine.inputNode
        // Tap in the node's native format so no implicit conversion is needed.
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when)
        }
        installed = true

        engine.prepare()
        try engine.start()
    }

    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let onChunk else { return }

        // Host time of this buffer's first sample, converted through the shared
        // timebase. If for some reason the buffer isn't host-time stamped, fall
        // back to "now" so we still produce a monotonic-ish stamp.
        let hostNanos: UInt64 = when.isHostTimeValid
            ? HostTime.nanos(fromHostTime: when.hostTime)
            : HostTime.nowNanos()

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)

        if let floatChannelData = buffer.floatChannelData {
            // AVAudioEngine input buffers are non-interleaved (deinterleaved) by
            // default: one pointer per channel. Interleave into a single array.
            if buffer.format.isInterleaved {
                // Single packed buffer already interleaved.
                let src = floatChannelData[0]
                interleaved.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src, count: frameCount * channelCount)
                }
            } else {
                for ch in 0..<channelCount {
                    let src = floatChannelData[ch]
                    for frame in 0..<frameCount {
                        interleaved[frame * channelCount + ch] = src[frame]
                    }
                }
            }
        }

        onChunk(AudioChunk(hostNanos: hostNanos, samples: interleaved))
    }

    func stop() {
        if installed {
            engine.inputNode.removeTap(onBus: 0)
            installed = false
        }
        if engine.isRunning {
            engine.stop()
        }
        onChunk = nil
    }
}
