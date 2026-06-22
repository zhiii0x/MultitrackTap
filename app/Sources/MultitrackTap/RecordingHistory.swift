import Foundation
import Observation
import os

/// One persisted record of a completed recording session.
///
/// Captured at `stopRecording` time and stored newest-first in
/// `RecordingHistoryStore`. `folderPath` points at the timestamped per-recording
/// subfolder (see `RecordingViewModel.currentRecordingFolder`), so the history
/// can reveal it in Finder later.
struct RecordingHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let stemCount: Int
    let folderPath: String
    let sampleRate: Int
    let format: String
    let stemNames: [String]

    init(id: UUID = UUID(),
         date: Date,
         durationSeconds: Double,
         stemCount: Int,
         folderPath: String,
         sampleRate: Int,
         format: String,
         stemNames: [String]) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.stemCount = stemCount
        self.folderPath = folderPath
        self.sampleRate = sampleRate
        self.format = format
        self.stemNames = stemNames
    }
}

/// Persistent, observable log of past recordings.
///
/// Backed by a JSON file at
/// `~/Library/Application Support/Multitrack Tap/history.json`. `entries` are
/// kept newest-first. Persistence failures are logged and swallowed — a write
/// error must never crash recording or block the UI.
@MainActor
@Observable
final class RecordingHistoryStore {
    private(set) var entries: [RecordingHistoryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.github.zhiii0x.MultitrackTap", category: "RecordingHistory")

    /// - Parameter directory: override for the storage directory (tests). When
    ///   nil, resolves `~/Library/Application Support/Multitrack Tap`.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    /// Application Support subfolder for this app, falling back to the temp dir
    /// if Application Support can't be resolved (it virtually always can).
    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Multitrack Tap", isDirectory: true)
    }

    // MARK: - Mutations

    /// Prepend a new entry (newest-first) and persist.
    func add(_ entry: RecordingHistoryEntry) {
        entries.insert(entry, at: 0)
        persist()
    }

    /// Remove a single entry (does NOT touch any recorded files on disk).
    func delete(_ entry: RecordingHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Remove all entries (does NOT touch any recorded files on disk).
    func clear() {
        entries.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([RecordingHistoryEntry].self, from: data)
        } catch {
            logger.error("Failed to load recording history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist recording history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
