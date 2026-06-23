import XCTest
@testable import MultitrackTap

/// Tests `RecordingHistoryStore`: add prepends newest-first and persists, delete
/// removes a single entry, and a fresh store loads what a prior store wrote
/// (JSON round-trip through a temp Application Support directory).
@MainActor
final class RecordingHistoryStoreTests: XCTestCase {

    // `nonisolated(unsafe)` so the nonisolated XCTest setUp/tearDown can set and
    // clean it up while the class is @MainActor. Safe: written once in setUp and
    // tests run serially, so there's no concurrent access. (Swift 6.0.x rejects
    // accessing a main-actor property from the nonisolated setUp; 6.2 allowed it.)
    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MTHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func makeEntry(_ name: String, seconds: Double) -> RecordingHistoryEntry {
        RecordingHistoryEntry(
            date: Date(),
            durationSeconds: seconds,
            stemCount: 2,
            folderPath: "/tmp/\(name)",
            sampleRate: 48000,
            format: "32-bit float",
            stemNames: ["Microphone", name])
    }

    func testAddPrependsNewestFirst() {
        let store = RecordingHistoryStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)

        let first = makeEntry("first", seconds: 10)
        let second = makeEntry("second", seconds: 20)
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.entries.count, 2)
        // Most recently added is first.
        XCTAssertEqual(store.entries[0].id, second.id)
        XCTAssertEqual(store.entries[1].id, first.id)
    }

    func testDeleteRemovesOnlyThatEntry() {
        let store = RecordingHistoryStore(directory: tempDir)
        let a = makeEntry("a", seconds: 5)
        let b = makeEntry("b", seconds: 6)
        store.add(a)
        store.add(b)

        store.delete(a)

        XCTAssertEqual(store.entries.map(\.id), [b.id])
    }

    func testPersistenceRoundTrip() {
        let entry = makeEntry("roundtrip", seconds: 42.5)
        do {
            let store = RecordingHistoryStore(directory: tempDir)
            store.add(entry)
        }

        // A fresh store over the same directory loads the persisted entry.
        let reloaded = RecordingHistoryStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.count, 1)
        let loaded = reloaded.entries[0]
        XCTAssertEqual(loaded.id, entry.id)
        XCTAssertEqual(loaded.durationSeconds, 42.5, accuracy: 0.001)
        XCTAssertEqual(loaded.stemCount, 2)
        XCTAssertEqual(loaded.sampleRate, 48000)
        XCTAssertEqual(loaded.format, "32-bit float")
        XCTAssertEqual(loaded.stemNames, ["Microphone", "roundtrip"])
    }

    func testClearRemovesAllAndPersists() {
        let store = RecordingHistoryStore(directory: tempDir)
        store.add(makeEntry("x", seconds: 1))
        store.add(makeEntry("y", seconds: 2))

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = RecordingHistoryStore(directory: tempDir)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }
}
