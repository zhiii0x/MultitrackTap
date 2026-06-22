import Foundation
import os
import MultitrackCore

/// Crash recovery for interrupted recordings.
///
/// While recording, an in-progress marker file is dropped in the recording
/// folder; a clean stop removes it. On launch, any folder still carrying the
/// marker was interrupted (crash / force-quit / power loss) — its WAV stems'
/// headers are repaired so they are valid, playable files, and the marker is
/// cleared. The streaming header is also flushed periodically while recording,
/// so the repair usually only needs to recover the final fraction of a second.
enum RecordingRecovery {
    static let markerName = ".recording"

    private static let logger = Logger(
        subsystem: "com.github.zhiii0x.MultitrackTap", category: "RecordingRecovery")

    static func markerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(markerName)
    }

    /// Write the in-progress marker (best effort).
    static func writeMarker(in folder: URL) {
        try? Data().write(to: markerURL(in: folder))
    }

    /// Remove the in-progress marker after a clean stop (best effort).
    static func removeMarker(in folder: URL) {
        try? FileManager.default.removeItem(at: markerURL(in: folder))
    }

    /// Scan `baseDirectory`'s immediate subfolders for interrupted recordings
    /// (those still carrying the marker), repair each stem's WAV header, and
    /// clear the marker. Returns the folders that were recovered. Safe to call at
    /// launch — never throws.
    @discardableResult
    static func recoverInterruptedRecordings(in baseDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var recovered: [URL] = []
        for folder in entries {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, fm.fileExists(atPath: markerURL(in: folder).path) else { continue }

            let wavs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "wav" } ?? []
            for wav in wavs {
                do {
                    if try WAVWriter.repairHeader(at: wav) {
                        logger.notice("Recovered stem \(wav.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    logger.error("Couldn't repair \(wav.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            removeMarker(in: folder)
            recovered.append(folder)
        }
        return recovered
    }
}
