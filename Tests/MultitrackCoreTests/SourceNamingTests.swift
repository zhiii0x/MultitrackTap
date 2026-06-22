import XCTest
@testable import MultitrackCore

final class SourceNamingTests: XCTestCase {
    func test_trackName_isHumanReadable() {
        XCTAssertEqual(SourceNaming.trackName(for: Source(id: "1", name: "Zoom", kind: .app)), "Zoom")
        XCTAssertEqual(SourceNaming.trackName(for: Source(id: "mic", name: "MacBook Pro Microphone", kind: .microphone)), "MacBook Pro Microphone")
    }

    func test_fileName_isFilesystemSafe() {
        XCTAssertEqual(SourceNaming.fileName(for: Source(id: "1", name: "Guest / Zoom", kind: .app)), "Guest - Zoom.wav")
        XCTAssertEqual(SourceNaming.fileName(for: Source(id: "1", name: "System", kind: .system)), "System.wav")
    }

    func test_fileName_deduplicatesCollisions() {
        let s = Source(id: "1", name: "Music", kind: .app)
        XCTAssertEqual(SourceNaming.fileName(for: s, existing: ["Music.wav"]), "Music 2.wav")
    }

    // MARK: - Empty / illegal names (Finding #5)

    func test_fileName_emptyName_fallsBackToId() {
        let s = Source(id: "track-42", name: "", kind: .app)
        XCTAssertEqual(SourceNaming.fileName(for: s), "track-42.wav")
    }

    func test_fileName_whitespaceOnlyName_fallsBackToId() {
        let s = Source(id: "track-42", name: "   ", kind: .app)
        XCTAssertEqual(SourceNaming.fileName(for: s), "track-42.wav")
    }

    func test_fileName_illegalSlashesName_producesNonDotWav() {
        // "///" → components split by '/' → ["","","",""] → joined with " - " → " -  -  - "
        // collapse whitespace → "- - -" → base = "- - -"
        // Not empty, so filename = "- - -.wav" (not ".wav")
        let s = Source(id: "track-42", name: "///", kind: .app)
        let name = SourceNaming.fileName(for: s)
        XCTAssertFalse(name.hasPrefix("."), "Should not produce a dotfile like .wav")
        XCTAssertTrue(name.hasSuffix(".wav"))
    }

    // MARK: - Whitespace collapse (Finding #6)

    func test_fileName_multipleSpaces_collapsed() {
        // "Foo    Bar" (4 spaces) should collapse to "Foo Bar"
        let s = Source(id: "1", name: "Foo    Bar", kind: .app)
        XCTAssertEqual(SourceNaming.fileName(for: s), "Foo Bar.wav")
    }
}
