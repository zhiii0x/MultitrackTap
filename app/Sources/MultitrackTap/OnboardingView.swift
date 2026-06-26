import SwiftUI
import AppKit
import AVFoundation
import MultitrackCore

/// First-launch onboarding: a full-window, 3-step flow (welcome → permissions →
/// how-to) shown by `RootView` instead of `RecordView` until completed.
///
/// Reuses the shared `RecordingViewModel` for permission state and requests
/// (so there is a single source of truth), and `OnboardingModel` to persist
/// completion. The how-to step's final action auto-handles the one-time Core
/// Audio relaunch when app-audio was just granted (see `needsRelaunchForAudioCapture`).
struct OnboardingView: View {
    @Environment(RecordingViewModel.self) private var model
    @Environment(OnboardingModel.self) private var onboarding

    enum Step: Int, CaseIterable { case welcome, permissions, howTo }
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 20) {
            content
                .id(step)
                .transition(.opacity)
            Spacer(minLength: 0)
            stepDots
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 560)
        .tint(Theme.accent)
        .background(WindowBackground(recording: nil))
        // Keep permission badges current if the user grants in System Settings
        // and returns, or flips state in another app.
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in model.refreshPermissions() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .howTo: howToStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Wordmark(size: 40)
            Text("Record every source as its own track")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Your mic and each app — captured separately and perfectly in sync, ready to mix.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            Spacer()
            Button {
                withAnimation(Theme.transition()) { step = .permissions }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Button("Skip setup") { onboarding.complete() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Two quick permissions")

            permissionRow(
                symbol: "mic.fill",
                title: "Microphone",
                detail: "Records your voice as its own track.",
                granted: model.micPermission == .allowed,
                action: requestMic)

            permissionRow(
                symbol: "speaker.wave.2.fill",
                title: "System & app audio",
                detail: "Captures the apps you choose, each on its own track.",
                granted: model.audioCapturePermission == .allowed,
                action: requestAudioCapture)

            if model.audioCapturePermission != .allowed {
                Text("macOS may ask you to restart the app once — we'll do that for you at the end.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                withAnimation(Theme.transition()) { step = .howTo }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            accentChip(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .help("Allowed")
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
        }
        .padding(14)
        .premiumCard(cornerRadius: 14)
    }

    // MARK: - Step 3: How to record

    private var howToStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("How to record")

            howToRow(1, "Pick your sources",
                     "Toggle on your mic, system audio, and any apps.")
            howToRow(2, "Choose an output folder",
                     "Where each track (stem) is saved.")
            howToRow(3, "Hit Record",
                     "Stop when done. Every source is a separate file.")

            Spacer()

            Button { finish() } label: {
                Text(model.needsRelaunchForAudioCapture
                     ? "Restart & start recording"
                     : "Start recording")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if model.needsRelaunchForAudioCapture {
                Text("one-time restart to finish audio setup")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func howToRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Shared bits

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Accent-tinted icon chip, matching the mic/system chips in `RecordView`.
    private func accentChip(_ symbol: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(LinearGradient(
                colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0.12)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent))
    }

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - Actions (reuse RecordView's permission flows exactly)

    private func requestMic() {
        // If denied, we can't re-prompt — open System Settings directly.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        } else {
            Task {
                await withCheckedContinuation { cont in
                    AVCaptureDevice.requestAccess(for: .audio) { _ in cont.resume() }
                }
                model.refreshPermissions()
            }
        }
    }

    private func requestAudioCapture() {
        // TCC preflight: 1 = denied → open Settings; else → request.
        if AudioCaptureTCC.preflight() == 1 {
            AudioCapturePermission.openSystemSettings()
        } else {
            Task {
                _ = await AudioCapturePermission.request()
                model.refreshPermissions()
            }
        }
    }

    /// Finish onboarding. If app-audio was newly granted this session, the HAL
    /// needs a relaunch to see processes — persist the "seen" flag, then relaunch
    /// (after restart the flag is set, so RootView shows the recorder directly).
    private func finish() {
        onboarding.complete()
        if model.needsRelaunchForAudioCapture {
            model.relaunch()
        }
    }
}
