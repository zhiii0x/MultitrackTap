import XCTest
@testable import MultitrackCore

final class WAVWriterTests: XCTestCase {
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }
    private func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o+1]) << 8
    }
    private func ascii(_ d: Data, _ o: Int, _ n: Int) -> String {
        String(bytes: d[o..<o+n], encoding: .ascii)!
    }
    private func f32(_ d: Data, _ i: Int) -> Float {
        let o = 44 + i * 4
        let bits = UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
        return Float(bitPattern: bits)
    }

    func test_writesValidFloatWavHeaderAndData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard)
        // 4 stereo frames = 8 interleaved samples
        try writer.append([0, 0, 0.5, -0.5, 1, -1, 0.25, -0.25])
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(ascii(d, 0, 4), "RIFF")
        XCTAssertEqual(ascii(d, 8, 4), "WAVE")
        XCTAssertEqual(ascii(d, 12, 4), "fmt ")
        XCTAssertEqual(u32(d, 16), 16)        // PCM/float fmt chunk size
        XCTAssertEqual(u16(d, 20), 3)         // IEEE float
        XCTAssertEqual(u16(d, 22), 2)         // channels
        XCTAssertEqual(u32(d, 24), 48000)     // sample rate
        XCTAssertEqual(u16(d, 32), 8)         // block align = 2ch * 4 bytes
        XCTAssertEqual(u16(d, 34), 32)        // bits per sample
        XCTAssertEqual(ascii(d, 36, 4), "data")
        XCTAssertEqual(u32(d, 40), 32)        // data size = 8 samples * 4 bytes
        XCTAssertEqual(d.count, 44 + 32)      // header + data
    }

    // MARK: - Overflow guard

    func test_riffChunkSize_throwsWhenTooLarge() {
        // Each sample is 4 bytes; need sampleCount * 1ch * 4 > UInt32.max - 36
        // UInt32.max = 4_294_967_295; threshold = (4_294_967_295 - 36) / 4 + 1 = 1_073_741_815
        let hugeSampleCount = Int(UInt32.max / 4) + 1
        XCTAssertThrowsError(try WAVWriter.riffChunkSize(sampleCount: hugeSampleCount, channelCount: 1)) { error in
            XCTAssertEqual(error as? WAVWriterError, .recordingTooLarge)
        }
    }

    func test_riffChunkSize_succeedsForReasonableRecording() throws {
        // 2h of 48k stereo = 345_600_000 frames * 2 interleaved samples per frame
        let size = try WAVWriter.riffChunkSize(sampleCount: 345_600_000 * 2, channelCount: 1)
        XCTAssertGreaterThan(size, 0)
    }

    // MARK: - Multi-chunk streaming

    func test_multiChunk_samplesAreContiguous() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard)
        try writer.append([0.1, 0.2, 0.3, 0.4])   // chunk 1: 2 stereo frames
        try writer.append([0.5, 0.6, 0.7, 0.8])   // chunk 2: 2 stereo frames
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(u32(d, 40), 32)   // dataSize = 8 samples * 4 bytes
        XCTAssertEqual(d.count, 44 + 32)
        XCTAssertEqual(f32(d, 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(f32(d, 1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(f32(d, 4), 0.5, accuracy: 0.0001)
        XCTAssertEqual(f32(d, 5), 0.6, accuracy: 0.0001)
    }

    // MARK: - Empty recording

    func test_emptyRecording_writesValidHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard)
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.count, 44)
        XCTAssertEqual(u32(d, 40), 0)   // dataSize = 0
    }

    // MARK: - Mono

    func test_mono_headerBlockAlignAndByteRate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mono-\(UUID().uuidString).wav")
        let monoFormat = AudioFormat(sampleRate: 48000, channelCount: 1)
        let writer = try WAVWriter(url: url, format: monoFormat)
        try writer.append([0.1, 0.2, 0.3])  // 3 mono frames
        try writer.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(u16(d, 22), 1)             // channels = 1
        XCTAssertEqual(u16(d, 32), 4)             // blockAlign = 1ch * 4 bytes
        XCTAssertEqual(u32(d, 28), 48000 * 4)     // byteRate = 48000 * 1 * 4
        XCTAssertEqual(u32(d, 40), 12)            // dataSize = 3 samples * 4 bytes
    }

    // MARK: - Crash safety

    func test_flushHeader_writesCurrentSizesWithoutClosing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, format: .standard)
        try writer.append([0.1, 0.2, 0.3, 0.4])    // 2 stereo frames -> 4 samples
        try writer.flushHeader()

        // Mid-recording read (no finalize yet) must already report the data.
        let mid = try Data(contentsOf: url)
        XCTAssertEqual(u32(mid, 40), UInt32(4 * 4))   // 4 samples * 4 bytes

        // Appending continues correctly after a flush, and finalize is exact.
        try writer.append([0.5, 0.6])                 // +1 frame
        try writer.finalize()
        let final = try Data(contentsOf: url)
        XCTAssertEqual(u32(final, 40), UInt32(6 * 4))
        XCTAssertEqual(final.count, 44 + 6 * 4)
        XCTAssertEqual(f32(final, 4), 0.5, accuracy: 0.0001)  // 3rd sample intact
    }

    func test_repairHeader_fixesUnfinalizedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-\(UUID().uuidString).wav")
        do {
            let writer = try WAVWriter(url: url, format: .standard)
            try writer.append([0.1, 0.2, 0.3, 0.4])   // 2 frames
            try writer.append([0.5, 0.6])              // 1 frame
            // No finalize(): writer deinits here, leaving a stale (0) header.
        }

        let before = try Data(contentsOf: url)
        XCTAssertEqual(u32(before, 40), 0)             // unfinalized -> header says 0 data

        XCTAssertTrue(try WAVWriter.repairHeader(at: url))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(u32(after, 40), UInt32(6 * 4))  // 3 frames stereo float = 24 bytes
        XCTAssertEqual(u32(after, 4), UInt32(36 + 6 * 4))
        XCTAssertEqual(f32(after, 4), 0.5, accuracy: 0.0001)

        XCTAssertFalse(try WAVWriter.repairHeader(at: url))   // idempotent
    }
}
