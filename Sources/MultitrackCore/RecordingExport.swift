import Foundation

public enum RecordingExport {
    public static func reaperStems(from result: RecordingResult, sampleRate: Double) -> [ReaperStem] {
        result.stems.map { stem in
            ReaperStem(
                name: SourceNaming.trackName(for: stem.source),
                fileName: stem.url.lastPathComponent,
                lengthSeconds: Double(stem.frameCount) / sampleRate)
        }
    }

    /// Writes `project.rpp` next to the stems and returns its URL.
    public static func writeReaperProject(for result: RecordingResult,
                                          in directory: URL,
                                          sampleRate: Double) throws -> URL {
        let stems = reaperStems(from: result, sampleRate: sampleRate)
        let text = ReaperProjectExporter.makeProjectText(sampleRate: sampleRate, stems: stems)
        let url = directory.appendingPathComponent("project.rpp")
        try Data(text.utf8).write(to: url)
        return url
    }
}
