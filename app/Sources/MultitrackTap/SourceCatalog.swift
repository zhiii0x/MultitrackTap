import Foundation
import AppKit
import MultitrackCore

/// Bridges the low-level Core Audio process enumeration (`AudioProcessList`)
/// into UI-facing `MultitrackCore.Source` values plus app icons.
///
/// Scope: microphone + system audio + per-app sources.
enum SourceCatalog {
    /// The microphone source. A fixed, always-available entry shown first in the
    /// UI. The id matches the one `MicrophoneTap` reports so naming/export line
    /// up.
    static let microphone = Source(id: "microphone", name: "Microphone", kind: .microphone)

    /// The system-audio source: a global tap that captures ALL system output.
    /// A fixed, always-available entry shown right after the microphone. The id
    /// matches the one `CoreAudioProcessTap.systemAudio()` reports.
    static let systemAudio = Source(id: "system", name: "System audio", kind: .system)

    /// All currently tappable application sources that a user would recognize,
    /// mapped to `MultitrackCore.Source` (kind `.app`), de-duplicated by bundle
    /// id and sorted by name.
    ///
    /// Two filters keep this list user-facing rather than a debug dump:
    ///   1. Processes without a bundle id are dropped: the app records a chosen
    ///      app by bundle id (`CoreAudioProcessTap(forBundleID:)`), and a
    ///      bundle-less process can't be selected that way.
    ///   2. Processes whose running application is NOT a regular,
    ///      Dock/UI-bearing app (`activationPolicy == .regular`) are dropped —
    ///      this filters out system audio daemons, agents and helpers
    ///      (`audiomxd`, `cloudpaird`, `ContinuityCaptureAgent`, `CoreSpeech`,
    ///      `Control Center`, …) that read like a debug tool, not real apps.
    ///
    /// The debug `--list` / `--match` paths still show EVERYTHING via
    /// `AudioProcessList.tappableProcesses()`; only this UI-facing list filters.
    static func availableAppSources() -> [Source] {
        let processes = (try? AudioProcessList.tappableProcesses()) ?? []

        // Index regular (Dock/UI-bearing) running apps. Each tappable process is
        // listed as the regular app that OWNS it — which may be the app's main
        // process OR a hidden helper/content/GPU subprocess. Browsers (Chrome,
        // Arc, Safari) and Electron apps (Slack, Discord, …) emit their audio from
        // such helpers, so a helper must be mapped back to its parent app or those
        // apps never appear in the list even while they're playing.
        struct RegularApp {
            let bundleID: String
            let name: String
            let pid: pid_t
            let bundleDir: String   // "" if unknown
        }
        var regulars: [RegularApp] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier else { continue }
            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? bid
            regulars.append(RegularApp(bundleID: bid,
                                       name: name,
                                       pid: app.processIdentifier,
                                       bundleDir: app.bundleURL?.path ?? ""))
        }

        // Resolve the regular app that owns a tappable process, mirroring the
        // matching in `CoreAudioProcessTap.resolveAll` so the list and what
        // actually gets recorded stay consistent:
        //   (a) same pid (the app's own main process);
        //   (b) exact bundle id;
        //   (c) bundle-id prefix — e.g. com.google.Chrome.helper → com.google.Chrome;
        //   (d) executable path inside the app's .app bundle — Arc-style helpers
        //       whose bundle id bears no relation to the parent.
        func owner(of proc: TappableProcess) -> RegularApp? {
            if let r = regulars.first(where: { $0.pid == proc.pid }) { return r }
            if let bid = proc.bundleID?.lowercased(), !bid.isEmpty {
                if let r = regulars.first(where: { $0.bundleID.lowercased() == bid }) { return r }
                if let r = regulars.first(where: { bid.hasPrefix($0.bundleID.lowercased() + ".") }) { return r }
            }
            let exec = AudioProcessList.executablePath(forPID: proc.pid)
            if !exec.isEmpty,
               let r = regulars.first(where: { !$0.bundleDir.isEmpty && exec.hasPrefix($0.bundleDir + "/") }) {
                return r
            }
            return nil
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs = Set<String>()
        var sources: [Source] = []
        for proc in processes {
            guard let app = owner(of: proc) else { continue }
            // Never list ourselves as a recordable source.
            if app.bundleID == ownBundleID { continue }
            // De-dupe by the OWNING app, so Chrome's several audio helpers collapse
            // into a single "Google Chrome" row. Recording that bundle id re-expands
            // to every matching helper via CoreAudioProcessTap.resolveAll.
            guard seenBundleIDs.insert(app.bundleID).inserted else { continue }
            sources.append(Source(id: app.bundleID, name: app.name, kind: .app))
        }
        return sources.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Best-effort app icon for a bundle id, for display next to a source row.
    ///
    /// Tries the running-application instance first (covers apps not installed
    /// in /Applications), then falls back to the on-disk bundle URL. Returns
    /// `nil` for the microphone / unknown bundles; the view supplies an SF
    /// Symbol fallback.
    static func appIcon(forBundleID bundleID: String) -> NSImage? {
        let workspace = NSWorkspace.shared

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon {
            return icon
        }
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return workspace.icon(forFile: url.path)
        }
        return nil
    }
}
