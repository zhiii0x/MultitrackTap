import Foundation

public struct ReaperStem: Equatable, Sendable {
    public let name: String
    public let fileName: String
    public let lengthSeconds: Double
    public init(name: String, fileName: String, lengthSeconds: Double) {
        self.name = name
        self.fileName = fileName
        self.lengthSeconds = lengthSeconds
    }
}

public enum ReaperProjectExporter {
    public static func makeProjectText(sampleRate: Double, stems: [ReaperStem]) -> String {
        var lines: [String] = []
        lines.append("<REAPER_PROJECT 0.1 \"6.0/macOS\" 0")
        lines.append("  SAMPLERATE \(Int(sampleRate)) 0 0")
        for stem in stems {
            lines.append("  <TRACK")
            lines.append("    NAME \(quoted(stem.name))")
            lines.append("    <ITEM")
            lines.append("      POSITION 0")
            lines.append("      LENGTH \(String(format: "%.6f", stem.lengthSeconds))")
            lines.append("      NAME \(quoted(stem.name))")
            lines.append("      <SOURCE WAVE")
            lines.append("        FILE \(quoted(stem.fileName))")
            lines.append("      >")
            lines.append("    >")
            lines.append("  >")
        }
        lines.append(">")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a value for a REAPER `.RPP` field. A REAPER token cannot span
    /// newlines and cannot contain its own delimiter, so we strip control
    /// characters and pick a delimiter (`"`, `'`, or `` ` ``) the value doesn't
    /// contain — matching REAPER's own quoting convention. This stops a
    /// maliciously-named source/app (the name comes from the app's own
    /// `localizedName`) from injecting extra lines or chunks into the project.
    private static func quoted(_ s: String) -> String {
        var clean = s
        for control in ["\n", "\r", "\u{0}"] {
            clean = clean.replacingOccurrences(of: control, with: " ")
        }
        if !clean.contains("\"") { return "\"\(clean)\"" }
        if !clean.contains("'") { return "'\(clean)'" }
        if !clean.contains("`") { return "`\(clean)`" }
        // Contains all three delimiters: drop double-quotes and fall back.
        return "\"\(clean.replacingOccurrences(of: "\"", with: ""))\""
    }
}
