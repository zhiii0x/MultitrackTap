import XCTest
import MultitrackCore
@testable import MultitrackTap

/// Tests the `MeteredTap` decorator that drives every level meter — both while
/// recording and while idle-previewing a selected source.
///
/// Contract under test:
///   - forwards `source`/`format` from the wrapped tap unchanged,
///   - on each chunk, publishes the interleaved peak (0...1) via `onLevel`,
///   - passes every chunk through to the coordinator callback untouched,
///   - emits a trailing `onLevel(0)` on `stop()` so the meter resets to silence.
///
/// A deterministic `StubTap` stands in for the real Core Audio / mic taps so the
/// metering logic is exercised with zero audio hardware or permission.
final class MeteredTapTests: XCTestCase {

    /// Emits a fixed list of chunks synchronously on `start`; records whether it
    /// was stopped. No real audio.
    private final class StubTap: AudioTap {
        let source: Source
        let format: AudioFormat
        private let chunks: [AudioChunk]
        private(set) var didStop = false

        init(source: Source = Source(id: "stub", name: "Stub", kind: .app),
             format: AudioFormat = .standard,
             chunks: [AudioChunk]) {
            self.source = source
            self.format = format
            self.chunks = chunks
        }

        func start(onChunk: @escaping (AudioChunk) -> Void) throws {
            for chunk in chunks { onChunk(chunk) }
        }

        func stop() { didStop = true }
    }

    func testForwardsSourceAndFormatUnchanged() {
        let stub = StubTap(
            source: Source(id: "com.example", name: "Example", kind: .app),
            format: AudioFormat(sampleRate: 44100, channelCount: 1),
            chunks: [])
        let metered = MeteredTap(wrapping: stub)

        XCTAssertEqual(metered.source.id, "com.example")
        XCTAssertEqual(metered.format.sampleRate, 44100)
        XCTAssertEqual(metered.format.channelCount, 1)
    }

    func testPublishesPeakLevelAndPassesChunksThrough() throws {
        // Two chunks: one quiet, one with a hot sample. Peak is the max |sample|.
        let quiet = AudioChunk(hostNanos: 1, samples: [0.0, -0.1, 0.1, -0.05])
        let loud = AudioChunk(hostNanos: 2, samples: [0.0, 0.25, -0.8, 0.3])
        let stub = StubTap(chunks: [quiet, loud])
        let metered = MeteredTap(wrapping: stub)

        var levels: [Float] = []
        metered.onLevel = { levels.append($0) }

        var forwarded: [AudioChunk] = []
        try metered.start { forwarded.append($0) }

        // One level per chunk (peak), in order. 0.1 then 0.8.
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(levels[1], 0.8, accuracy: 1e-6)

        // Chunks pass through untouched (same count, same host stamps + samples).
        XCTAssertEqual(forwarded.map(\.hostNanos), [1, 2])
        XCTAssertEqual(forwarded[1].samples, loud.samples)
    }

    func testPeakIsClampedToOne() throws {
        // Out-of-range samples must clamp to 1, never exceed it.
        let hot = AudioChunk(hostNanos: 0, samples: [1.7, -2.3, 0.4])
        let stub = StubTap(chunks: [hot])
        let metered = MeteredTap(wrapping: stub)

        var level: Float = -1
        metered.onLevel = { level = $0 }
        try metered.start { _ in }

        XCTAssertEqual(level, 1.0, accuracy: 1e-6)
    }

    func testStopResetsLevelToZeroAndStopsWrappedTap() throws {
        let stub = StubTap(chunks: [AudioChunk(hostNanos: 0, samples: [0.5])])
        let metered = MeteredTap(wrapping: stub)

        var levels: [Float] = []
        metered.onLevel = { levels.append($0) }
        try metered.start { _ in }
        metered.stop()

        // Last published level is 0 (meter resets to silence on stop).
        XCTAssertEqual(levels.last, 0)
        XCTAssertTrue(stub.didStop, "stop() must tear down the wrapped tap")
    }
}
