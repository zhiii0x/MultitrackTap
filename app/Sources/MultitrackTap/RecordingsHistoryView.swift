import SwiftUI
import AppKit
import MultitrackCore

/// The Recordings window: a newest-first log of past recordings, each revealing
/// its timestamped folder in Finder. Reads the shared `RecordingHistoryStore`
/// and `RecordingViewModel` from the environment (both injected at App level).
struct RecordingsHistoryView: View {
    @Environment(RecordingHistoryStore.self) private var store
    @Environment(RecordingViewModel.self) private var model

    @State private var showClearConfirmation = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .tint(Theme.accent)
        .background(WindowBackground(recording: nil))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openRecordingsFolder()
                } label: {
                    Label("Open Recordings Folder", systemImage: "folder")
                }
                .help("Reveal the configured recordings folder in Finder")

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
                .help("Remove every history entry (does not delete files)")
            }
        }
        .confirmationDialog(
            "Clear all recording history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the history list only. Your recorded files stay on disk.")
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.entries) { entry in
                    HistoryRow(
                        entry: entry,
                        onReveal: { reveal(entry) },
                        onDelete: { store.delete(entry) })
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No recordings yet")
                .font(.title3.weight(.semibold))
            Text("Your past recordings will appear here, newest first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    /// Reveal an entry's folder in Finder. The folder may have been moved or
    /// deleted by the user; the row disables this when missing.
    private func reveal(_ entry: RecordingHistoryEntry) {
        let url = URL(fileURLWithPath: entry.folderPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openRecordingsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([model.outputDirectory])
    }
}

// MARK: - History row

/// One recording: date-time, duration, stem count, and a format summary, plus
/// per-row Show in Finder + delete actions.
private struct HistoryRow: View {
    let entry: RecordingHistoryEntry
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var folderExists: Bool {
        FileManager.default.fileExists(atPath: entry.folderPath)
    }

    var body: some View {
        HStack(spacing: 12) {
            iconChip

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.date.formatted(
                    date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onReveal()
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!folderExists)
            .help(folderExists ? "Show in Finder" : "Folder no longer exists")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from history (keeps files)")
        }
        .padding(12)
        .premiumCard(cornerRadius: 12)
        // A gentle lift on hover so rows feel responsive.
        .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 8 : 0, y: 3)
        .onHover { isHovering in
            withAnimation(Theme.transition(0.25)) { hovering = isHovering }
        }
    }

    /// The accent-tinted waveform chip: subtle vertical gradient + hairline rim.
    private var iconChip: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return shape
            .fill(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom))
            .overlay(shape.strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent))
    }

    /// "0:42 · 3 stems · 48 kHz · 32-bit float"
    private var detailLine: String {
        var parts: [String] = [durationString, stemCountString]
        parts.append("\(sampleRateLabel) · \(entry.format)")
        return parts.joined(separator: " · ")
    }

    private var durationString: String {
        let total = Int(entry.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var stemCountString: String {
        "\(entry.stemCount) stem\(entry.stemCount == 1 ? "" : "s")"
    }

    /// "48 kHz" / "44.1 kHz".
    private var sampleRateLabel: String {
        let khz = Double(entry.sampleRate) / 1000
        let formatted = khz == khz.rounded()
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(formatted) kHz"
    }
}
