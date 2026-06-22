import XCTest
@testable import MultitrackTap

/// Regression tests for the process-tap delivery-rate selection.
///
/// Bug: a process tap whose buffers arrive at the output device's rate (e.g.
/// 44.1 kHz) was tagged with the tap's `kAudioTapPropertyFormat` rate (48 kHz)
/// and never resampled, so the stem played back ~8.7% too fast. The fix picks
/// the OUTPUT device's nominal rate over the (often stale) tap / aggregate-input
/// rates.
final class ProcessTapRateTests: XCTestCase {
    func test_prefersOutputNominalOverStaleTapAndAggregate() {
        // The exact bug scenario: output is 44.1k, but the tap reports 48k and the
        // freshly-created aggregate's input format still reads a stale 48k.
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: 44100, aggregateInput: 48000, tapRate: 48000),
            44100)
    }

    func test_fallsBackToAggregateThenTap() {
        // No output-nominal reading -> use the aggregate input rate.
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: nil, aggregateInput: 96000, tapRate: 48000),
            96000)
        // Neither available -> fall back to the tap rate.
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: nil, aggregateInput: nil, tapRate: 44100),
            44100)
    }

    func test_ignoresZeroOrInvalidReadings() {
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: 0, aggregateInput: 0, tapRate: 48000),
            48000)
        // All invalid -> last-resort default.
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: 0, aggregateInput: nil, tapRate: 0),
            48000)
    }

    func test_alreadyAtProjectRate_isUnchanged() {
        XCTAssertEqual(
            CoreAudioProcessTap.deliveryRate(outputNominal: 48000, aggregateInput: 48000, tapRate: 48000),
            48000)
    }
}
