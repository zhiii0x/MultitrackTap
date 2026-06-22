import Foundation

public enum SourceNaming {
    public static func trackName(for source: Source) -> String { source.name }

    public static func fileName(for source: Source, existing: Set<String> = []) -> String {
        var base = sanitize(source.name)
        if base.isEmpty {
            base = sanitize(source.id)
        }
        if base.isEmpty {
            base = "track"
        }
        var candidate = "\(base).wav"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(n).wav"
            n += 1
        }
        return candidate
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " - ")
        // Collapse any run of whitespace to a single space
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
