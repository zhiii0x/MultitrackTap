import SwiftUI
import AppKit
import Foundation
import MultitrackCore

/// The SwiftUI app. NOT marked `@main` — the real entry point is `Main` below,
/// which first handles headless debug flags (so the engine can be verified
/// without a GUI) and only then launches this `App`.
///
/// A SINGLE `RecordingViewModel` is created here at the App level and injected
/// into the environment, so the record window and the menu-bar extra both drive
/// — and reflect — the exact same recording state.
struct MultitrackTapApp: App {
    @State private var model = RecordingViewModel()
    /// The persistent recordings history, created once at the App level and
    /// shared (via `.environment`) with the record window, the history window,
    /// and the view model that appends to it on each successful stop.
    @State private var history = RecordingHistoryStore()
    /// First-launch onboarding state, shared with `RootView` and the
    /// "Show Welcome…" command so both drive the same instance.
    @State private var onboarding = OnboardingModel()

    init() {
        // Register Settings defaults before any view (or the view model) reads
        // them, so the very first recording uses the intended defaults even if
        // the user never opens the Settings window.
        SettingsKeys.registerDefaults()
        // Give the view model the shared history store so stop can log to it.
        model.historyStore = history
        // Recover any recording interrupted by a previous crash/force-quit:
        // repair its stem headers so they're valid files, then clear the marker.
        RecordingRecovery.recoverInterruptedRecordings(in: model.outputDirectory)
    }

    var body: some Scene {
        WindowGroup("Multitrack Tap", id: "main") {
            RootView()
                .environment(model)
                .environment(history)
                .environment(onboarding)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the stock "About Multitrack Tap" with our branded window.
            CommandGroup(replacing: .appInfo) {
                AboutMenuCommand()
            }
            // Replay the first-launch onboarding on demand.
            CommandGroup(after: .appInfo) {
                ShowWelcomeMenuCommand(onboarding: onboarding)
            }
            // ⌘0 opens the Recordings window, mirroring the in-window button.
            CommandGroup(after: .windowList) {
                RecordingsMenuCommand()
            }
        }

        // The recordings history log, opened via the header button, the
        // Window menu item (⌘0), or the menu-bar extra.
        Window("Recordings", id: "history") {
            RecordingsHistoryView()
                .environment(model)
                .environment(history)
        }
        .defaultSize(width: 480, height: 520)
        .windowResizability(.contentMinSize)

        // Standard Preferences window (⌘,) + a "Settings…" menu item.
        Settings {
            SettingsView()
        }

        // Custom About window, opened by the "About Multitrack Tap" menu item
        // (which replaces the default about panel — see .commands above).
        Window("About Multitrack Tap", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Menu-bar quick start/stop, backed by the SAME view model.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isRecording ? "stop.circle" : "record.circle")
        }
    }
}

/// The "Recordings" item in the Window menu (⌘0). Split out so it can own the
/// `openWindow` environment without complicating the scene body.
private struct RecordingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Recordings") {
            openWindow(id: "history")
        }
        .keyboardShortcut("0", modifiers: [.command])
    }
}

/// The "About Multitrack Tap" app-menu item. Owns the `openWindow` environment
/// so it can open the custom About window scene.
private struct AboutMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Multitrack Tap") {
            openWindow(id: "about")
        }
    }
}

/// The "Show Welcome…" app-menu item. Replays first-launch onboarding without
/// clearing the completed flag, and brings the main window forward.
private struct ShowWelcomeMenuCommand: View {
    let onboarding: OnboardingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Welcome…") {
            onboarding.replay()
            openWindow(id: "main")
        }
    }
}

/// Contents of the menu-bar extra: recording status, a Start/Stop button, and
/// "Open Window". Bound to the shared `RecordingViewModel`.
private struct MenuBarContent: View {
    @Bindable var model: RecordingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.isRecording {
                Text("Recording \(elapsedString)")
            } else {
                Text("Idle")
            }

            Button(model.isRecording ? "Stop" : "Start") {
                if model.isRecording {
                    model.stopRecording()
                } else {
                    // startRecording is async (permission request must run off
                    // the main thread); kick it off without blocking the menu.
                    Task { await model.startRecording() }
                }
            }
            .disabled(!model.isRecording && !model.hasSelection)

            Divider()

            Button("Open Window") {
                openWindow(id: "main")
            }

            Button("Recordings") {
                openWindow(id: "history")
            }

            Divider()

            Button("Quit Multitrack Tap") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var elapsedString: String {
        let total = Int(model.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Real process entry point.
///
/// A `@main struct: App` can't branch on `CommandLine.arguments` before
/// SwiftUI takes over, so we use a manual `@main enum`:
///   - `--list`         → print tappable processes, exit (headless smoke test).
///   - `--match <id>`   → print `resolveAll` matches for a bundle id, exit
///                        (no audio-capture permission required).
///   - otherwise        → launch the SwiftUI app.
@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        switch args.first {
        case "--list":
            listProcesses()
            exit(0)
        case "--apps":
            listAppSources()
            exit(0)
        case "--match":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("Usage: MultitrackTap --match <bundle-id>\n".utf8))
                exit(1)
            }
            matchProcesses(bundleID: args[1])
            exit(0)
        default:
            MultitrackTapApp.main()
        }
    }

    // MARK: - Headless debug commands

    private static func listProcesses() {
        do {
            let processes = try AudioProcessList.tappableProcesses()
            guard !processes.isEmpty else {
                print("No process audio objects found.")
                return
            }
            print("Tappable audio processes (bundle id — name):")
            for proc in processes {
                let bundle = proc.bundleID ?? "pid:\(proc.pid)"
                print("  \(bundle)  —  \(proc.name)")
            }
        } catch {
            FileHandle.standardError.write(Data("Failed to list processes: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Prints the user-facing picker list (`SourceCatalog.availableAppSources`) —
    /// the filtered sources with helper/content/GPU subprocesses attributed to
    /// their parent app — so the list logic can be checked without the GUI.
    private static func listAppSources() {
        let sources = SourceCatalog.availableAppSources()
        guard !sources.isEmpty else {
            print("No app sources (no regular app is producing audio, or audio-capture isn't granted).")
            return
        }
        print("Picker app sources (bundle id — name):")
        for source in sources {
            print("  \(source.id)  —  \(source.name)")
        }
    }

    private static func matchProcesses(bundleID: String) {
        do {
            let matches = try AudioProcessList.resolveAll(bundleID: bundleID)
            print("Matched \(matches.count) process\(matches.count == 1 ? "" : "es") for '\(bundleID)':")
            for proc in matches {
                let bid = proc.bundleID ?? "—"
                let execPath = AudioProcessList.executablePath(forPID: proc.pid)
                let execDisplay = execPath.isEmpty ? "(exec path unavailable)" : execPath
                print("  pid=\(proc.pid)  bundleID=\(bid)  name=\(proc.name)")
                print("    exec: \(execDisplay)")
            }
            print("Total: \(matches.count)")
        } catch {
            FileHandle.standardError.write(Data("Match failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
