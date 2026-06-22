import SwiftUI

/// The custom About window (replaces the default macOS about panel). Reuses the
/// code-drawn `Wordmark` and the shared `WindowBackground` so it reads as the
/// same crafted product, and pulls its version from the bundle so it never
/// drifts from `Info.plist`.
struct AboutView: View {
    // Update this if the public repo location changes.
    private let repoURL = URL(string: "https://github.com/zhiii0x/MultitrackTap")!
    private let licenseURL = URL(string: "https://opensource.org/license/mit")!

    var body: some View {
        VStack(spacing: 14) {
            Wordmark(size: 40)

            Text("Free, open-source multitrack recording for macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Records your mic, system audio, and each chosen app to "
                 + "separate, time-synced WAV stems — then builds a "
                 + "ready-to-open Reaper session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider().frame(width: 220)

            HStack(spacing: 18) {
                Link("GitHub", destination: repoURL)
                Link("MIT License", destination: licenseURL)
            }
            .font(.callout)

            Text("Version \(appVersion) · © 2026 Zhiii")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .tint(Theme.accent)
        .padding(28)
        .frame(width: 380)
        .background(WindowBackground(recording: nil))
    }

    /// "0.1 (1)" — short version + build, read from the app bundle.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    AboutView()
}
