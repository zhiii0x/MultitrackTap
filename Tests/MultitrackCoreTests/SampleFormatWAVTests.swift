import XCTest
@testable import MultitrackCore

/// Tests for per-sample-format WAV writing (int16 / int24 / float32).
/// float32 behavior is covered by the existing `WAVWriterTests`; these focus on
/// the new integer encodings and the `sampleFormat` parameter threading.
final class SampleFormatWAVTests: XCTestCase {
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }
    private func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o+1]) << 8
    }

    // MARK: - displayName

    func test_sampleFormat_displayNames() {
        XCTAssertEqual(SampleFormat.int16.displayName, "16-bit")
        XCTAssertEqual(SampleFormat.int24.displayName, "24-bit")
        XCTAssertEqual(SampleFormat.float32.displayName, "32-bit float")
    }

    func test_sampleFormat_allCases() {
        XCTAssertEqual(SampleFormat.allCases, [.int16, .int24, .float32])
    }

    func test_sampleFormat_rawValuesRoundTrip() {
        XCTAssertEqual(SampleFormat(rawValue: "int16"), .int16)
        XCTAssertEqual(SampleFormat(rawValue: "int24"), .int24)
        XCTAssertEqual(SampleFormat(rawValue: "float32"), .float32)
    }

    // MARK: - int16 header

    func test_int16_header() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i16h-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard, sampleFormat: .int16)
        try writer.append([0, 0, 0.5, -0.5])  // 2 stereo frames
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(u16(d, 20), 1)             // PCM
        XCTAssertEqual(u16(d, 22), 2)             // channels
        XCTAssertEqual(u16(d, 32), 2 * 2)         // blockAlign = 2 bytes * 2 channels
        XCTAssertEqual(u16(d, 34), 16)            // bits per sample
        XCTAssertEqual(u32(d, 24), 48000)         // sample rate
        XCTAssertEqual(u32(d, 28), 48000 * 2 * 2) // byteRate = rate * ch * 2 bytes
        XCTAssertEqual(u32(d, 40), UInt32(4 * 2)) // dataSize = 4 samples * 2 bytes
        XCTAssertEqual(d.count, 44 + 4 * 2)
    }

    // MARK: - int24 header

    func test_int24_header() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i24h-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard, sampleFormat: .int24)
        try writer.append([0, 0, 0.5, -0.5])  // 2 stereo frames
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(u16(d, 20), 1)             // PCM
        XCTAssertEqual(u16(d, 22), 2)             // channels
        XCTAssertEqual(u16(d, 32), 3 * 2)         // blockAlign = 3 bytes * 2 channels
        XCTAssertEqual(u16(d, 34), 24)            // bits per sample
        XCTAssertEqual(u32(d, 28), 48000 * 2 * 3) // byteRate = rate * ch * 3 bytes
        XCTAssertEqual(u32(d, 40), UInt32(4 * 3)) // dataSize = 4 samples * 3 bytes
        XCTAssertEqual(d.count, 44 + 4 * 3)
    }

    // MARK: - int16 sample bytes

    func test_int16_sampleBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i16b-\(UUID().uuidString).wav")
        let mono = AudioFormat(sampleRate: 48000, channelCount: 1)
        let writer = try WAVWriter(url: url, format: mono, sampleFormat: .int16)
        try writer.append([1.0, -1.0, 0.0])
        try writer.finalize()

        let d = try Data(contentsOf: url)
        // 1.0 -> 32767 = 0x7FFF -> bytes FF 7F
        XCTAssertEqual([d[44], d[45]], [0xFF, 0x7F])
        // -1.0 -> -32767 = 0x8001 -> bytes 01 80
        XCTAssertEqual([d[46], d[47]], [0x01, 0x80])
        // 0.0 -> 0 -> bytes 00 00
        XCTAssertEqual([d[48], d[49]], [0x00, 0x00])
    }

    // MARK: - int24 sample bytes

    func test_int24_sampleBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i24b-\(UUID().uuidString).wav")
        let mono = AudioFormat(sampleRate: 48000, channelCount: 1)
        let writer = try WAVWriter(url: url, format: mono, sampleFormat: .int24)
        try writer.append([1.0])
        try writer.finalize()

        let d = try Data(contentsOf: url)
        // 1.0 -> 8388607 = 0x7FFFFF -> little-endian bytes FF FF 7F
        XCTAssertEqual([d[44], d[45], d[46]], [0xFF, 0xFF, 0x7F])
    }

    func test_int24_negativeFullScale() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i24n-\(UUID().uuidString).wav")
        let mono = AudioFormat(sampleRate: 48000, channelCount: 1)
        let writer = try WAVWriter(url: url, format: mono, sampleFormat: .int24)
        try writer.append([-1.0])
        try writer.finalize()

        let d = try Data(contentsOf: url)
        // -1.0 -> -8388607 = 0xFF800001 (24-bit two's complement: 0x800001)
        // little-endian bytes: 01 00 80
        XCTAssertEqual([d[44], d[45], d[46]], [0x01, 0x00, 0x80])
    }

    // MARK: - clamping beyond [-1, 1]

    func test_int16_clampsOutOfRange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i16c-\(UUID().uuidString).wav")
        let mono = AudioFormat(sampleRate: 48000, channelCount: 1)
        let writer = try WAVWriter(url: url, format: mono, sampleFormat: .int16)
        try writer.append([2.0, -2.0])
        try writer.finalize()

        let d = try Data(contentsOf: url)
        // clamp 2.0 -> 1.0 -> 32767 = 0x7FFF
        XCTAssertEqual([d[44], d[45]], [0xFF, 0x7F])
        // clamp -2.0 -> -1.0 -> -32767 = 0x8001
        XCTAssertEqual([d[46], d[47]], [0x01, 0x80])
    }

    // MARK: - RecordingCoordinator threading

    func test_coordinator_int16_producesSixteenBitWAV() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recfmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [AudioChunk(hostNanos: 0, samples: [0.1, 0.2, 0.3, 0.4])])

        let coordinator = RecordingCoordinator(
            taps: [mic], outputDirectory: dir, sampleFormat: .int16)
        try coordinator.start(startHostNanos: 0)
        let result = try coordinator.stop()

        XCTAssertEqual(result.stems.count, 1)
        let d = try Data(contentsOf: result.stems[0].url)
        XCTAssertEqual(u16(d, 20), 1)     // PCM
        XCTAssertEqual(u16(d, 34), 16)    // 16-bit
        XCTAssertEqual(u16(d, 32), 2 * 2) // blockAlign = 2 bytes * 2 channels
        XCTAssertEqual(u32(d, 40), UInt32(4 * 2)) // 4 samples * 2 bytes
    }
}
