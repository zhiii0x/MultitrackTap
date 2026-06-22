import SwiftUI
import MultitrackCore

/// Shared `@AppStorage` keys and defaults for the Settings panel.
///
/// Centralizing them here keeps `SettingsView` (which writes them) and
/// `RecordingViewModel` (which reads them at start/stop time) in agreement.
/// Defaults are registered in `UserDefaults.standard` at app launch so a value
/// read before the Settings window is ever opened still returns the intended
/// default.
enum SettingsKeys {
    static let targetSampleRate = "targetSampleRate"
    static let sampleFormat = "sampleFormat"
    static let revealAfterRecording = "revealAfterRecording"
    static let generateReaperProject = "generateReaperProject"

    static let defaultSampleRate = 48000
    static let defaultSampleFormat = SampleFormat.float32
    static let defaultRevealAfterRecording = true
    static let defaultGenerateReaperProject = true

    /// Register defaults so reads return the intended value even before the user
    /// ever opens Settings. Idempotent; safe to call at every launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            targetSampleRate: defaultSampleRate,
            sampleFormat: defaultSampleFormat.rawValue,
            revealAfterRecording: defaultRevealAfterRecording,
            generateReaperProject: defaultGenerateReaperProject,
        ])
    }
}

/// The Preferences/Settings panel (⌘,). Grouped `Form` for a native macOS look,
/// backed entirely by `@AppStorage` so changes persist and apply to the next
/// recording.
struct SettingsView: View {
    @AppStorage(SettingsKeys.targetSampleRate)
    private var sampleRate: Int = SettingsKeys.defaultSampleRate
    @AppStorage(SettingsKeys.sampleFormat)
    private var sampleFormatRaw: String = SettingsKeys.defaultSampleFormat.rawValue
    @AppStorage(SettingsKeys.revealAfterRecording)
    private var revealAfterRecording: Bool = SettingsKeys.defaultRevealAfterRecording
    @AppStorage(SettingsKeys.generateReaperProject)
    private var generateReaperProject: Bool = SettingsKeys.defaultGenerateReaperProject

    private let sampleRates: [Int] = [44100, 48000, 88200, 96000]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Wordmark(size: 24)
                Text("Free, open-source multitrack recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 2)

            Form {
            Section {
                Picker("Sample rate", selection: $sampleRate) {
                    ForEach(sampleRates, id: \.self) { rate in
                        Text(Self.label(forSampleRate: rate)).tag(rate)
                    }
                }
                Picker("Bit format", selection: $sampleFormatRaw) {
                    ForEach(SampleFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
            } header: {
                Text("Audio format")
            } footer: {
                Text("32-bit float is recommended for editing — no clipping. "
                     + "16-/24-bit produce smaller files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Generate Reaper project", isOn: $generateReaperProject)
                Toggle("Reveal in Finder after recording", isOn: $revealAfterRecording)
            } header: {
                Text("After recording")
            } footer: {
                Text("A Reaper project (.rpp) lines up every stem on a synced "
                     + "timeline. Turn it off to keep just the WAV stems.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
            .formStyle(.grouped)
        }
        .tint(Theme.accent)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func label(forSampleRate rate: Int) -> String {
        let khz = Double(rate) / 1000
        // Drop a trailing ".0" (48.0 -> "48"), keep one decimal otherwise.
        let formatted = khz == khz.rounded()
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(formatted) kHz"
    }
}
