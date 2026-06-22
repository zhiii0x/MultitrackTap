import SwiftUI
import AppKit

/// Audio-capture (TCC) permission status, derived from `AudioCaptureTCC.preflight()`.
///
/// On macOS 26 the audio-capture grant lives under
/// System Settings → Privacy & Security → Screen & System Audio Recording.
enum AudioCapturePermission {
    case authorized
    case denied
    /// Never prompted, or status otherwise unknown. The first record attempt
    /// triggers the system prompt from inside the bundled app.
    case undetermined

    /// Reads the current status without prompting.
    static var current: AudioCapturePermission {
        switch AudioCaptureTCC.preflight() {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    var isAuthorized: Bool { self == .authorized }

    /// Requests audio-capture permission OFF the main thread; returns true if
    /// authorized. Safe to call from a SwiftUI async action — the blocking
    /// `requestBlocking()` call runs on a background queue, never on the main actor.
    static func request() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                if AudioCaptureTCC.preflight() == 0 { cont.resume(returning: true); return }
                let granted = AudioCaptureTCC.requestBlocking()  // safe: not on main thread
                cont.resume(returning: granted)
            }
        }
    }

    /// Opens the relevant System Settings pane. Audio capture is granted under
    /// the Screen & System Audio Recording privacy pane on macOS 26.
    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sheet shown when audio-capture permission is not yet granted. Explains why
/// the app needs the grant and offers a shortcut to the System Settings pane.
struct PermissionSheet: View {
    /// Optional extra detail (e.g. the error thrown by `CoreAudioProcessTap`).
    var detail: String?
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Audio Recording permission needed")
                        .font(.headline)
                    Text("Multitrack Tap needs System Audio Recording permission")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("""
            To record audio from other apps, grant Multitrack Tap access under \
            Privacy & Security → Screen & System Audio Recording, then return here \
            and start recording again.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    AudioCapturePermission.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
