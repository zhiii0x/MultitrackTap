import SwiftUI
import AppKit
import AVFoundation
import MultitrackCore

/// The main record window: a crafted Mac utility for recording mic + apps to
/// separate, time-synced stems.
///
/// Layout: a header that foregrounds the elapsed clock while recording, an
/// output-folder card, a sources card (mic + system audio pinned, then real
/// apps), and a prominent Record/Stop button with recording-state choreography.
struct RecordView: View {
    /// The shared recording view model, injected at the App level so the
    /// window and the menu-bar extra drive the same state.
    @Environment(RecordingViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var showPermissionSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            outputCard
            sourcesCard
            footer
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 560)
        .tint(Theme.accent)
        .background(WindowBackground(recording: model.isRecording))
        // Window appear (re)starts idle preview for selected sources via
        // refreshSources → reconcilePreviewTaps; window disappear stops it so the
        // mic engine / aggregate devices don't keep running with no window.
        .onAppear {
            model.refreshSources()
            model.refreshPermissions()
            model.startObservingAudioProcesses()
        }
        .onDisappear {
            model.stopIdlePreview()
            model.stopObservingAudioProcesses()
        }
        // Refresh permission badges AND re-enumerate sources when the user returns
        // from System Settings (or any other app). `didBecomeActiveNotification`
        // fires on every app-activation — the right trigger after the user flips a
        // toggle in System Settings, or starts/stops audio in another app. Without
        // the source refresh, a just-granted permission would leave the app list
        // stale (empty) until the window is reopened.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            model.refreshPermissions()
            model.refreshSources()
        }
        .sheet(isPresented: $showPermissionSheet) {
            PermissionSheet(detail: model.errorMessage) {
                showPermissionSheet = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Wordmark(size: 22)
                Text("Record mic + apps to separate, time-synced stems.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.isRecording {
                recordingClock
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    openWindow(id: "history")
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("View past recordings")
                .transition(.opacity)
            }
        }
        .animation(Theme.transition(0.4), value: model.isRecording)
    }

    /// The prominent, monospaced elapsed clock with a breathing record dot.
    private var recordingClock: some View {
        HStack(spacing: 9) {
            RecordDot(reduceMotion: reduceMotion)
            Text(elapsedString)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.record)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .premiumCard(cornerRadius: 12, tint: Theme.record)
    }

    // MARK: - Output folder card

    private var outputCard: some View {
        HStack(spacing: 12) {
            roundedIcon(systemName: "folder.fill", tint: Theme.accent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("OUTPUT FOLDER")
                    .sectionLabel()
                Text(model.outputDirectory.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.outputDirectory.path)
            }
            Spacer(minLength: 8)
            Button("Choose…") { chooseOutputFolder() }
                .disabled(model.isRecording)
        }
        .padding(14)
        .premiumCard(cornerRadius: 14)
    }

    // MARK: - Sources card

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SOURCES")
                    .sectionLabel()
                Spacer()
                if !model.isRecording {
                    Button {
                        withAnimation(Theme.transition(0.35)) { model.refreshSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh app list")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    SourceRow(
                        title: "Microphone",
                        symbol: "mic.fill",
                        isOn: micBinding,
                        level: model.micLevel,
                        disabled: model.isRecording,
                        permission: model.micPermission,
                        onAllowTap: {
                            // If denied, we can't re-prompt — open System Settings directly.
                            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                                let url = URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                                NSWorkspace.shared.open(url)
                            } else {
                                Task {
                                    await withCheckedContinuation { cont in
                                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                                            cont.resume()
                                        }
                                    }
                                    model.refreshPermissions()
                                }
                            }
                        })
                    SourceRow(
                        title: "System audio",
                        symbol: "speaker.wave.2.fill",
                        isOn: systemBinding,
                        level: model.systemLevel,
                        disabled: model.isRecording,
                        permission: model.audioCapturePermission,
                        onAllowTap: {
                            // TCC preflight: 1 = denied → open Settings; else → request.
                            if AudioCaptureTCC.preflight() == 1 {
                                AudioCapturePermission.openSystemSettings()
                            } else {
                                Task {
                                    _ = await AudioCapturePermission.request()
                                    model.refreshPermissions()
                                }
                            }
                        })

                    if !model.appSources.isEmpty {
                        Divider()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }

                    if model.appSources.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.appSources) { row in
                            SourceRow(
                                title: row.source.name,
                                appIcon: row.icon,
                                isOn: Binding(get: { row.isSelected },
                                              set: { model.setAppSelected(row, $0) }),
                                level: row.level,
                                disabled: model.isRecording,
                                permission: model.audioCapturePermission,
                                onAllowTap: {
                                    if AudioCaptureTCC.preflight() == 1 {
                                        AudioCapturePermission.openSystemSettings()
                                    } else {
                                        Task {
                                            _ = await AudioCapturePermission.request()
                                            model.refreshPermissions()
                                        }
                                    }
                                })
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .premiumCard(cornerRadius: 16)
        .disabled(model.isRecording || model.isStarting)
    }

    /// The app-list empty state, split three ways so the message matches the real
    /// reason the list is empty:
    ///   1. Permission not granted  → point at the System-audio Allow above.
    ///   2. Granted, but the app launched WITHOUT it → Core Audio stays blind to
    ///      every process until relaunch; offer a one-click Quit & Reopen.
    ///   3. Granted and active, nothing playing → the genuine "no audio" case.
    @ViewBuilder
    private var emptyState: some View {
        if model.audioCapturePermission != .allowed {
            emptyStateContent(
                icon: "waveform.badge.exclamationmark",
                title: "System Audio Recording needed",
                detail: "Grant it with the Allow button above — then apps playing audio appear here.")
        } else if model.needsRelaunchForAudioCapture {
            emptyStateContent(
                icon: "arrow.clockwise.circle",
                title: "Reopen to finish enabling",
                detail: "macOS applies the System Audio Recording grant only after you quit and reopen Multitrack Tap.",
                buttonTitle: "Quit & Reopen",
                buttonIcon: "arrow.clockwise",
                action: { model.relaunch() })
        } else {
            emptyStateContent(
                icon: "speaker.slash",
                title: "No apps are playing audio.",
                detail: "Start audio in an app to capture it.",
                buttonTitle: "Refresh",
                buttonIcon: "arrow.clockwise",
                action: { withAnimation(Theme.transition(0.35)) { model.refreshSources() } })
        }
    }

    private func emptyStateContent(
        icon: String,
        title: String,
        detail: String,
        buttonTitle: String? = nil,
        buttonIcon: String = "arrow.clockwise",
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle, let action {
                Button(action: action) {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.errorMessage, !showPermissionSheet {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = model.startWarning, model.isRecording {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RecordButton(
                isRecording: model.isRecording,
                enabled: model.isRecording || model.hasSelection,
                reduceMotion: reduceMotion,
                action: toggleRecording)
                .keyboardShortcut("r", modifiers: [.command])

            if let summary = model.lastResultSummary, !model.isRecording {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.20, green: 0.80, blue: 0.45))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary)
                            .font(.callout)
                        Button("Show in Finder") { model.revealInFinder() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .tint(Theme.accent)
                    }
                    Spacer()
                }
                .padding(12)
                .premiumCard(cornerRadius: 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Theme.transition(0.35), value: model.lastResultSummary)
    }

    // MARK: - Bindings

    // Selection bindings route through the view model's toggle methods (not a
    // direct `$model.micSelected` write) so each toggle starts/stops that
    // source's idle level-preview tap.
    private var micBinding: Binding<Bool> {
        Binding(get: { model.micSelected },
                set: { model.setMicSelected($0) })
    }

    private var systemBinding: Binding<Bool> {
        Binding(get: { model.systemSelected },
                set: { model.setSystemSelected($0) })
    }

    // MARK: - Shared bits

    /// A rounded, accent-tinted icon container used for the special mic/system
    /// rows and the output-folder card, so they read as crafted, not default.
    /// A subtle vertical gradient + hairline rim give it a tactile chip feel.
    private func roundedIcon(systemName: String, tint: Color, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        return shape
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.24), tint.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom))
            .overlay(shape.strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint))
    }

    // MARK: - Actions

    private func toggleRecording() {
        if model.isRecording {
            model.stopRecording()
            return
        }

        // startRecording is async (permission request must run off the main thread).
        // After it completes, surface a permission sheet if needed.
        Task {
            await model.startRecording()
            if let error = model.errorMessage,
               error.localizedCaseInsensitiveContains("denied") ||
               error.localizedCaseInsensitiveContains("authoriz") ||
               error.localizedCaseInsensitiveContains("AudioCapture") ||
               error.localizedCaseInsensitiveContains("permission") {
                showPermissionSheet = true
            }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = model.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
        }
    }

    private var elapsedString: String {
        let total = Int(model.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Source row

/// A single, tappable source row: a larger app icon (or accent-tinted SF Symbol
/// container for special sources), a name, a meter slot (live `LevelMeter` when
/// permission is granted, or a compact "Allow" affordance when blocked), and a
/// checkmark toggle. The whole row toggles selection, with a hover highlight and
/// an accent-tinted background when selected.
///
/// The meter slot is the only place where permission is communicated: a working
/// meter signals "ready to record"; the subtle amber "Allow" button signals
/// "needs permission" — no extra badge, so the selection checkmark on the right
/// is the only checkmark in the row.
private struct SourceRow: View {
    let title: String
    var symbol: String? = nil
    var appIcon: NSImage? = nil
    @Binding var isOn: Bool
    var level: Float
    var disabled: Bool
    /// Which permission applies to this row. Drives the meter slot.
    var permission: RecordingViewModel.RecordPermission = .needsPermission
    /// Called when the user taps the "Allow" affordance. Should request permission
    /// if undetermined, or open System Settings if denied — one tap handles both.
    var onAllowTap: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 28, height: 28)

            Text(title)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Meter slot: fixed width so row layout is stable whether the meter
            // or the "Allow" affordance is showing.
            meterSlot
                .frame(width: 110)

            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: isOn)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !disabled else { return }
            withAnimation(Theme.transition(0.25)) { isOn.toggle() }
        }
        .onHover { isHovering in
            withAnimation(Theme.transition(0.2)) { hovering = isHovering }
        }
        .opacity(disabled ? 0.85 : 1)
    }

    /// The meter slot shows the live `LevelMeter` when permission is granted,
    /// or a compact amber "Allow" button when permission is needed.
    /// Both fill the same 110 pt slot so row width never shifts.
    @ViewBuilder
    private var meterSlot: some View {
        switch permission {
        case .allowed:
            LevelMeter(level: level)
        case .needsPermission:
            // Understated "Allow" affordance — small lock glyph + label, amber-
            // tinted, right-aligned so it occupies the trailing edge of the slot
            // just like the meter would. Plain button style keeps it quiet; a
            // stack of these across multiple app rows should read as a column of
            // gentle hints, not a row of loud calls to action.
            Button {
                onAllowTap?()
            } label: {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("Allow")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.orange.opacity(0.80))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Allow recording for this source")
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let symbol {
            // Accent-tinted chip: subtle vertical gradient + hairline rim.
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom))
                .overlay(shape.strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent))
        } else if let appIcon {
            // Crisp app icon: rounded corner mask + a tiny lift shadow.
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
        } else {
            Image(systemName: "app.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isOn {
            // Selected: a smooth accent-tinted gradient with a hairline rim.
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.accent.opacity(hovering ? 0.26 : 0.20),
                            Theme.accent.opacity(hovering ? 0.16 : 0.11),
                        ],
                        startPoint: .top,
                        endPoint: .bottom))
                .overlay(shape.strokeBorder(Theme.accent.opacity(0.28), lineWidth: 0.5))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.06))
        } else {
            shape.fill(Color.clear)
        }
    }
}

// MARK: - Record button

/// The primary action. Full-width, large, accent (idle) → red (recording), with
/// a press-scale micro-interaction and a **breathing outer glow** while
/// recording (reduce-motion safe). A tactile gradient fill + soft outer glow give
/// it weight.
private struct RecordButton: View {
    let isRecording: Bool
    let enabled: Bool
    let reduceMotion: Bool
    let action: () -> Void

    /// Drives the ~1.2 s sine breathing of the recording glow.
    @State private var breathe = false

    var body: some View {
        // While recording, the outer glow breathes between these two radii. Under
        // reduce-motion (or idle) it sits at a steady value.
        let glowActive = isRecording && !reduceMotion
        let glowRadius: CGFloat = isRecording ? (glowActive && breathe ? 22 : 14) : 0
        let glowOpacity: Double = isRecording ? (reduceMotion ? 0.30 : (breathe ? 0.55 : 0.38)) : 0

        Button(action: action) {
            Label(isRecording ? "Stop" : "Record",
                  systemImage: isRecording ? "stop.fill" : "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(ProminentPressButtonStyle(tint: isRecording ? Theme.record : Theme.accent))
        .controlSize(.large)
        .disabled(!enabled)
        // Breathing outer glow while recording.
        .shadow(color: Theme.record.opacity(glowOpacity), radius: glowRadius)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.2)
                    .repeatForever(autoreverses: true),
                   value: breathe)
        .animation(Theme.transition(0.4), value: isRecording)
        .onChange(of: isRecording) { _, recording in
            // Start/stop the breathing loop with the recording state. Toggling
            // `breathe` under a repeatForever animation produces the sine pulse.
            if recording && !reduceMotion {
                breathe = true
            } else {
                breathe = false
            }
        }
    }
}

/// A prominent, tinted button style with a tactile vertical gradient (tint →
/// slightly darker), a continuous-corner shape, a thin top sheen, and a soft
/// outer glow. Scales to 0.97 on press with the signature easing.
private struct ProminentPressButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return configuration.label
            .foregroundStyle(.white)
            .background(
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(isEnabled ? 1 : 0.5),
                                tint.opacity(isEnabled ? 0.82 : 0.4),
                            ],
                            startPoint: .top,
                            endPoint: .bottom))
                    // Thin top sheen so the fill reads lit-from-above.
                    .overlay(
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .clear],
                                    startPoint: .top,
                                    endPoint: .center))
                            .blendMode(.plusLighter))
                    // Crisp rim.
                    .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    // Resting soft glow that lifts the button off the window.
                    .shadow(color: tint.opacity(isEnabled ? 0.35 : 0), radius: 8, x: 0, y: 3))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.12),
                       value: configuration.isPressed)
    }
}

// MARK: - Pulsing record dot

/// A red dot that breathes (~1.2s sine) while recording — the ambient motion
/// layer for "live" state. Static under reduced motion.
private struct RecordDot: View {
    let reduceMotion: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Theme.record)
            .frame(width: 11, height: 11)
            .scaleEffect(animate && !reduceMotion ? 1.18 : 1.0)
            .opacity(animate && !reduceMotion ? 0.55 : 1.0)
            .shadow(color: Theme.record.opacity(0.6), radius: animate && !reduceMotion ? 5 : 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
            .accessibilityHidden(true)
    }
}
