import XCTest
@testable import MultitrackCore

final class ReaperProjectExporterTests: XCTestCase {
    func test_generatesDeterministicRPP() {
        let stems = [
            ReaperStem(name: "Me", fileName: "Me.wav", lengthSeconds: 12.5),
            ReaperStem(name: "Guest - Zoom", fileName: "Guest - Zoom.wav", lengthSeconds: 12.5),
        ]
        let text = ReaperProjectExporter.makeProjectText(sampleRate: 48000, stems: stems)
        let expected = """
        <REAPER_PROJECT 0.1 "6.0/macOS" 0
          SAMPLERATE 48000 0 0
          <TRACK
            NAME "Me"
            <ITEM
              POSITION 0
              LENGTH 12.500000
              NAME "Me"
              <SOURCE WAVE
                FILE "Me.wav"
              >
            >
          >
          <TRACK
            NAME "Guest - Zoom"
            <ITEM
              POSITION 0
              LENGTH 12.500000
              NAME "Guest - Zoom"
              <SOURCE WAVE
                FILE "Guest - Zoom.wav"
              >
            >
          >
        >

        """
        XCTAssertEqual(text, expected)
    }

    func test_maliciousSourceName_cannotInjectRPPStructure() {
        // A hostile running app could name itself with quotes + newlines +
        // REAPER tokens to try to inject chunks into the generated project.
        let evil = "Evil\" 0\n  >\n  <TRACK NAME \"pwn"
        let evilText = ReaperProjectExporter.makeProjectText(
            sampleRate: 48000,
            stems: [ReaperStem(name: evil, fileName: "x.wav", lengthSeconds: 1.0)])
        let baseline = ReaperProjectExporter.makeProjectText(
            sampleRate: 48000,
            stems: [ReaperStem(name: "Evil", fileName: "x.wav", lengthSeconds: 1.0)])
        // No extra lines: the newlines in the name must be neutralized, so
        // structural injection (new <TRACK / stray >) is impossible.
        XCTAssertEqual(
            evilText.split(separator: "\n", omittingEmptySubsequences: false).count,
            baseline.split(separator: "\n", omittingEmptySubsequences: false).count)
        // The embedded double-quote must not terminate the token early: REAPER's
        // delimiter is switched to single quotes instead.
        XCTAssertTrue(evilText.contains("NAME 'Evil"))
    }
}
