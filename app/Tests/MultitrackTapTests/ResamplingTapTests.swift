import XCTest
import MultitrackCore
@testable import MultitrackTap

/// Tests the `ResamplingTap` decorator: it must report the target rate, preserve
/// channel count + `hostNanos`, and forward a non-empty resampled chunk.
final class ResamplingTapTests: XCTestCase {

    /// Minimal `AudioTap` stub that emits one known chunk synchronously on
    /// `start`, at a fixed native format.
    private final class StubTap: AudioTap {
        let source: Source
        let format: AudioFormat
        private let chunk: AudioChunk

        init(format: AudioFormat, chunk: AudioChunk) {
            self.source = Source(id: "stub", name: "Stub", kind: .system)
            self.format = format
            self.chunk = chunk
        }

        func start(onChunk: @escaping (AudioChunk) -> Void) throws { onChunk(chunk) }
        func stop() {}
    }

    func testReportsTargetSampleRateAndPreservesChannelCount() {
        // Mono 44.1 kHz source — channel count must be preserved (no upmix).
        let stub = StubTap(
            format: AudioFormat(sampleRate: 44100, channelCount: 1),
            chunk: AudioChunk(hostNanos: 0, samples: [Float](repeating: 0, count: 441)))
        let resampler = ResamplingTap(wrapping: stub, target: 48000)

        XCTAssertEqual(resampler.format.sampleRate, 48000)
        XCTAssertEqual(resampler.format.channelCount, 1, "channel count must be preserved")
        XCTAssertEqual(resampler.source.id, "stub", "source is forwarded unchanged")
    }

    func testForwardsNonEmptyChunkAtNewRateWithOriginalHostNanos() throws {
        // 10 ms of mono 44.1 kHz audio = 441 frames. At 48 kHz that's ~480 frames.
        let inputFrames = 441
        let hostNanos: UInt64 = 123_456_789
        // A simple ramp so the converter has real signal to resample.
        let samples = (0..<inputFrames).map { Float($0) / Float(inputFrames) }
        let stub = StubTap(
            format: AudioFormat(sampleRate: 44100, channelCount: 1),
            chunk: AudioChunk(hostNanos: hostNanos, samples: samples))
        let resampler = ResamplingTap(wrapping: stub, target: 48000)

        var received: [AudioChunk] = []
        try resampler.start { received.append($0) }
        resampler.stop()

        XCTAssertFalse(received.isEmpty, "decorator must forward at least one chunk")
        let out = try XCTUnwrap(received.first)

        // hostNanos is preserved (start time unchanged).
        XCTAssertEqual(out.hostNanos, hostNanos)

        // Output is non-empty and at the new rate: 441 frames @ 44.1k -> ~480
        // frames @ 48k. Allow slack for the converter's internal buffering.
        let outFrames = out.samples.count // mono, so samples == frames
        XCTAssertGreaterThan(outFrames, 0)
        let expected = Int(Double(inputFrames) * 48000.0 / 44100.0) // ~480
        XCTAssertEqual(Double(outFrames), Double(expected), accuracy: 64,
                       "resampled frame count should be near the 48k-rate estimate")
    }

    func testStereoChannelCountPreserved() {
        let stub = StubTap(
            format: AudioFormat(sampleRate: 44100, channelCount: 2),
            chunk: AudioChunk(hostNanos: 7, samples: [Float](repeating: 0, count: 882)))
        let resampler = ResamplingTap(wrapping: stub, target: 48000)
        XCTAssertEqual(resampler.format.channelCount, 2)
        XCTAssertEqual(resampler.format.sampleRate, 48000)
    }
}
