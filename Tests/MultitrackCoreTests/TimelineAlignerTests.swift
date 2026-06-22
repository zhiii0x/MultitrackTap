import XCTest
@testable import MultitrackCore

final class TimelineAlignerTests: XCTestCase {
    func test_firstSampleAtStart_needsNoPadding() {
        let pad = TimelineAligner.leadingSilenceFrames(
            startHostNanos: 1_000_000_000,
            firstSampleHostNanos: 1_000_000_000,
            sampleRate: 48000)
        XCTAssertEqual(pad, 0)
    }

    func test_tenMillisecondsLate_pads480FramesAt48k() {
        let pad = TimelineAligner.leadingSilenceFrames(
            startHostNanos: 1_000_000_000,
            firstSampleHostNanos: 1_010_000_000, // +10ms
            sampleRate: 48000)
        XCTAssertEqual(pad, 480) // 0.010 * 48000
    }

    func test_sampleArrivingBeforeStart_clampsToZero() {
        let pad = TimelineAligner.leadingSilenceFrames(
            startHostNanos: 1_000_000_000,
            firstSampleHostNanos: 999_000_000,
            sampleRate: 48000)
        XCTAssertEqual(pad, 0)
    }
}
