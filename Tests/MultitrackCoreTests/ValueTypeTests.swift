import XCTest
@testable import MultitrackCore

final class ValueTypeTests: XCTestCase {
    func test_standardFormat_is48kStereo() {
        let f = AudioFormat.standard
        XCTAssertEqual(f.sampleRate, 48000)
        XCTAssertEqual(f.channelCount, 2)
    }

    func test_audioChunk_holdsTimestampAndSamples() {
        let chunk = AudioChunk(hostNanos: 42, samples: [0.1, -0.1])
        XCTAssertEqual(chunk.hostNanos, 42)
        XCTAssertEqual(chunk.samples, [0.1, -0.1])
    }

    func test_source_kindAndName() {
        let s = Source(id: "mic", name: "Microphone", kind: .microphone)
        XCTAssertEqual(s.kind, .microphone)
        XCTAssertEqual(s.name, "Microphone")
    }
}
