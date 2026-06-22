import XCTest
@testable import MultitrackCore

final class RecordingCoordinatorTests: XCTestCase {
    private func floats(_ d: Data, count: Int, at frameOffset: Int, channels: Int) -> [Float] {
        let byteOffset = 44 + frameOffset * channels * 4
        var out: [Float] = []
        for i in 0..<count {
            let o = byteOffset + i * 4
            let bits = UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
            out.append(Float(bitPattern: bits))
        }
        return out
    }

    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }

    func test_lateSource_isPaddedSoStemsAlign() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [AudioChunk(hostNanos: 1_000_000_000, samples: [0.5, 0.5, 0.5, 0.5])]) // 2 frames
        let app = FakeTap(
            source: Source(id: "app", name: "Zoom", kind: .app),
            chunks: [AudioChunk(hostNanos: 1_010_000_000, samples: [0.9, 0.9])]) // 1 frame, +10ms

        let coordinator = RecordingCoordinator(taps: [mic, app], outputDirectory: dir)
        try coordinator.start(startHostNanos: 1_000_000_000)
        let result = try coordinator.stop()

        // Two stems written.
        XCTAssertEqual(result.stems.count, 2)

        // Zoom stem padded by 480 frames of silence (10ms @ 48k), then 1 real frame.
        let zoomURL = dir.appendingPathComponent("Zoom.wav")
        let d = try Data(contentsOf: zoomURL)
        let leading = floats(d, count: 4, at: 0, channels: 2) // first 2 frames
        XCTAssertEqual(leading, [0, 0, 0, 0])                 // silence
        let firstReal = floats(d, count: 2, at: 480, channels: 2)
        XCTAssertEqual(firstReal, [0.9, 0.9])                 // real audio at frame 480
        // Total frames = 480 pad + 1 real = 481 -> data size 481*2*4
        let dataSize = UInt32(d[40]) | UInt32(d[41]) << 8 | UInt32(d[42]) << 16 | UInt32(d[43]) << 24
        XCTAssertEqual(Int(dataSize), 481 * 2 * 4)
    }

    func test_multiChunk_frameCountCorrect() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [
                AudioChunk(hostNanos: 1_000_000_000, samples: [0.1, 0.2, 0.3, 0.4]),   // 2 stereo frames
                AudioChunk(hostNanos: 1_000_000_000, samples: [0.5, 0.6, 0.7, 0.8]),   // 2 stereo frames
            ])

        let coordinator = RecordingCoordinator(taps: [mic], outputDirectory: dir)
        try coordinator.start(startHostNanos: 1_000_000_000)
        let result = try coordinator.stop()

        XCTAssertEqual(result.stems.count, 1)
        XCTAssertEqual(result.stems[0].frameCount, 4)  // 4 stereo frames total

        let d = try Data(contentsOf: result.stems[0].url)
        XCTAssertEqual(u32(d, 40), UInt32(4 * 2 * 4))   // 4 frames * 2ch * 4 bytes
    }

    func test_emptyTap_writesValidZeroLengthWAV() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [])

        let coordinator = RecordingCoordinator(taps: [mic], outputDirectory: dir)
        try coordinator.start(startHostNanos: 1_000_000_000)
        let result = try coordinator.stop()

        XCTAssertEqual(result.stems.count, 1)
        XCTAssertEqual(result.stems[0].frameCount, 0)

        let d = try Data(contentsOf: result.stems[0].url)
        XCTAssertEqual(d.count, 44)
        XCTAssertEqual(u32(d, 40), 0)   // dataSize = 0
    }

    func test_filenameCollision_bothFilesExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tap1 = FakeTap(
            source: Source(id: "a", name: "Music", kind: .app),
            chunks: [AudioChunk(hostNanos: 0, samples: [0.1, 0.1])])
        let tap2 = FakeTap(
            source: Source(id: "b", name: "Music", kind: .app),
            chunks: [AudioChunk(hostNanos: 0, samples: [0.2, 0.2])])

        let coordinator = RecordingCoordinator(taps: [tap1, tap2], outputDirectory: dir)
        try coordinator.start(startHostNanos: 0)
        let result = try coordinator.stop()

        XCTAssertEqual(result.stems.count, 2)
        let names = result.stems.map { $0.url.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["Music 2.wav", "Music.wav"])
        for stem in result.stems {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stem.url.path))
        }
    }

    func test_start_throwsWhenOutputDirectoryMissing() {
        let badDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let tap = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [AudioChunk(hostNanos: 0, samples: [0.1, 0.1])])
        let coordinator = RecordingCoordinator(taps: [tap], outputDirectory: badDir)
        XCTAssertThrowsError(try coordinator.start(startHostNanos: 0))
    }

    // MARK: - Per-source failure isolation

    private struct TapStartError: Error {}

    func test_failingSource_doesNotAbortTheRest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let good = FakeTap(source: Source(id: "mic", name: "Mic", kind: .microphone),
                           chunks: [AudioChunk(hostNanos: 0, samples: [0.5, 0.5])])
        let bad = FakeTap(source: Source(id: "bad", name: "Bad", kind: .app),
                          startError: TapStartError())

        let coordinator = RecordingCoordinator(taps: [good, bad], outputDirectory: dir)
        try coordinator.start(startHostNanos: 0)        // must NOT throw — the good source started
        let result = try coordinator.stop()

        XCTAssertEqual(result.stems.count, 1)
        XCTAssertEqual(result.stems.first?.source.id, "mic")
        // The failed source's empty stem file is cleaned up.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Bad.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Mic.wav").path))
    }

    func test_allSourcesFailToStart_throws() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("isoall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bad = FakeTap(source: Source(id: "bad", name: "Bad", kind: .app),
                          startError: TapStartError())
        let coordinator = RecordingCoordinator(taps: [bad], outputDirectory: dir)
        XCTAssertThrowsError(try coordinator.start(startHostNanos: 0))
    }

    // MARK: - Crash safety (periodic header flush)

    func test_periodicHeaderFlush_keepsHeaderCurrentBeforeFinalize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = FakeTap(
            source: Source(id: "mic", name: "Mic", kind: .microphone),
            chunks: [
                AudioChunk(hostNanos: 0, samples: [0.1, 0.1, 0.2, 0.2]),   // 2 frames
                AudioChunk(hostNanos: 0, samples: [0.3, 0.3, 0.4, 0.4]),   // 2 frames
            ])
        // Flush every 2 frames so the header is current after the synchronous emit.
        let coordinator = RecordingCoordinator(
            taps: [mic], outputDirectory: dir, headerFlushFrames: 2)
        try coordinator.start(startHostNanos: 0)

        // Simulate a crash: read WITHOUT calling stop()/finalize().
        let d = try Data(contentsOf: dir.appendingPathComponent("Mic.wav"))
        XCTAssertEqual(u32(d, 40), UInt32(4 * 2 * 4))   // 4 frames * 2ch * 4 bytes, flushed in place
    }
}
