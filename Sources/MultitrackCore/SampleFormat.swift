/// The on-disk sample encoding for recorded WAV stems.
///
/// `int16`/`int24` write PCM (WAVE format tag 1); `float32` writes IEEE float
/// (tag 3). Raw values are stable strings suitable for persistence (e.g.
/// `@AppStorage`).
public enum SampleFormat: String, CaseIterable, Sendable {
    case int16
    case int24
    case float32

    /// Human-readable label for pickers ("16-bit" / "24-bit" / "32-bit float").
    public var displayName: String {
        switch self {
        case .int16: return "16-bit"
        case .int24: return "24-bit"
        case .float32: return "32-bit float"
        }
    }
}
