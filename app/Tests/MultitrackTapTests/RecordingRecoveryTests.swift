import XCTest
import MultitrackCore
@testable import MultitrackTap

final class RecordingRecoveryTests: XCTestCase {
    private func dataSize(_ url: URL) throws -> UInt32 {
        let d = try Data(contentsOf: url)
        return UInt32(d[40]) | UInt32(d[41]) << 8 | UInt32(d[42]) << 16 | UInt32(d[43]) << 24
    }

    func test_recoversMarkedFolder_repairsHeaderAndClearsMarker() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("2026-06-22 12-00-00")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // An interrupted stem: data appended but never finalized -> header says 0.
        let wav = folder.appendingPathComponent("Mic.wav")
        do {
            let writer = try WAVWriter(url: wav, format: .standard)
            try writer.append([0.1, 0.2, 0.3, 0.4])   // 2 stereo frames
        }
        RecordingRecovery.writeMarker(in: folder)

        XCTAssertEqual(try dataSize(wav), 0)   // stale before recovery
        XCTAssertTrue(fm.fileExists(atPath: RecordingRecovery.markerURL(in: folder).path))

        let recovered = RecordingRecovery.recoverInterruptedRecordings(in: base)

        XCTAssertEqual(recovered.map { $0.lastPathComponent }, [folder.lastPathComponent])
        XCTAssertFalse(fm.fileExists(atPath: RecordingRecovery.markerURL(in: folder).path))  // marker cleared
        XCTAssertEqual(try dataSize(wav), UInt32(2 * 2 * 4))   // header repaired: 2 frames * 2ch * 4 bytes
    }

    func test_unmarkedFolder_isLeftAlone() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("recovery2-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("finished")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("Mic.wav")
        do {
            let writer = try WAVWriter(url: wav, format: .standard)
            try writer.append([0.1, 0.2])
            try writer.finalize()
        }
        // No marker -> this folder was a clean recording and must be left untouched.
        XCTAssertTrue(RecordingRecovery.recoverInterruptedRecordings(in: base).isEmpty)
        XCTAssertEqual(try dataSize(wav), UInt32(1 * 2 * 4))
    }
}
