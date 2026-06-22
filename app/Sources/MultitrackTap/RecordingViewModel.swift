import Foundation
import AppKit
import AVFoundation
import AudioToolbox
import Observation
import MultitrackCore

/// One selectable application row in the record window.
@MainActor
@Observable
final class AppSourceRow: Identifiable {
    let source: Source
    var isSelected: Bool = false
    /// Live peak level 0...1 while recording; decays toward 0 otherwise.
    var level: Float = 0
    let icon: NSImage?

    nonisolated var id: SourceID { source.id }

    init(source: Source, icon: NSImage?) {
        self.source = source
        self.icon = icon
    }
}

/// Drives the record window: source selection, recording lifecycle, live
/// levels, output folder, and the post-recording summary.
///
/// All mutable state is main-actor isolated. Level callbacks arrive on audio
/// threads and hop back to the main actor before mutating published state.
@MainActor
@Observable
final class RecordingViewModel {
    // MARK: - Permission status

    /// Collapsed two-state permission for a single source row.
    /// `.allowed` = TCC authorized; `.needsPermission` = denied or not-determined.
    enum RecordPermission {
        case allowed
        case needsPermission
    }

    /// Microphone permission status (AVFoundation `kTCCServiceMicrophone`).
    private(set) var micPermission: RecordPermission = .needsPermission
    /// System-audio + every app-source permission status (TCC `kTCCServiceAudioCapture`).
    /// All non-mic sources share the same grant, so one property covers them all.
    private(set) var audioCapturePermission: RecordPermission = .needsPermission

    /// Audio-capture authorization as seen at PROCESS LAUNCH. If the app launches
    /// without the grant, Core Audio creates this process's HAL connection
    /// unauthorized — and it keeps returning an EMPTY process list (and silent
    /// taps) even after the user grants the permission mid-session. Only a fresh
    /// process (relaunch) gets an authorized connection. Captured by the
    /// stored-property initializer, before `init` runs, so it reflects the true
    /// launch state and never changes afterwards.
    private let launchedAuthorized = (AudioCaptureTCC.preflight() == 0)

    /// True when the grant is now in place but the app launched WITHOUT it, so
    /// Core Audio surfaces no tappable processes until the app is quit and
    /// reopened. Drives the "reopen to finish enabling" guidance in the UI.
    /// Updated by `refreshPermissions()`.
    private(set) var needsRelaunchForAudioCapture = false

    /// Recomputes `micPermission` and `audioCapturePermission` from the current
    /// TCC state. Call on appear, on app-activation, and after any permission
    /// request resolves.
    func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? .allowed : .needsPermission
        let audioCaptureAuthorized = AudioCaptureTCC.preflight() == 0
        audioCapturePermission = audioCaptureAuthorized ? .allowed : .needsPermission
        // Authorized now, but not at launch → Core Audio won't see processes
        // until a relaunch establishes a fresh, authorized HAL connection.
        needsRelaunchForAudioCapture = audioCaptureAuthorized && !launchedAuthorized
    }

    /// Quits and reopens the app so Core Audio establishes a fresh, authorized
    /// HAL connection (see `needsRelaunchForAudioCapture`). Spawns a detached
    /// shell that waits for THIS process to exit, then reopens the bundle —
    /// reliable regardless of how long teardown takes. Safe because the app is
    /// not sandboxed.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Self.shellQuoted(Bundle.main.bundlePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \(bundle)"]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Single-quotes a path for safe interpolation into a `/bin/sh -c` string
    /// (the bundle path contains a space: ".../Multitrack Tap.app").
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Sources
    var appSources: [AppSourceRow] = []
    var micSelected: Bool = true
    var micLevel: Float = 0
    /// System-audio source (global tap capturing all system output), listed
    /// right after the microphone with its own selection + level meter.
    var systemSelected: Bool = false
    var systemLevel: Float = 0

    // MARK: Output
    var outputDirectory: URL

    /// History log appended to on each successful stop. Injected at the App
    /// level so the window, menu bar, and history window share one store.
    @ObservationIgnored var historyStore: RecordingHistoryStore?

    // MARK: Recording state
    private(set) var isRecording: Bool = false
    /// True from the moment `startRecording()` passes its `hasSelection` guard
    /// until `isRecording` flips to `true` (success) or an early `return`
    /// (failure/cancel). Closes the window during which a SwiftUI toggle or a
    /// returning async permission Task could re-start a preview tap on the same
    /// device we're about to record for real.
    private(set) var isStarting: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastResultSummary: String?
    private(set) var lastOutputDirectory: URL?
    /// The timestamped per-recording subfolder created at `startRecording` time
    /// and used as the coordinator/Reaper output dir. The post-recording summary
    /// and "Show in Finder" point here, NOT at the configured parent folder.
    private(set) var currentRecordingFolder: URL?
    /// User-facing error from the last start/stop attempt (e.g. TCC denied).
    var errorMessage: String?
    /// Non-fatal note shown while recording when one or more selected sources
    /// were skipped (e.g. an app couldn't be tapped). Recording proceeds with the
    /// rest. Cleared on the next start and on stop.
    private(set) var startWarning: String?

    // MARK: Private engine state
    private var coordinator: RecordingCoordinator?
    private var meteredTaps: [MeteredTap] = []
    /// Active idle level-preview taps, keyed by source id. These run a real tap
    /// (mic / app / system) wrapped in `MeteredTap` purely to drive each selected
    /// source's level meter WHILE NOT RECORDING — no coordinator, no WAV, no files.
    ///
    /// Marked `nonisolated(unsafe)` so `deinit` (nonisolated) can stop every tap
    /// without a main-actor hop. All other access is main-actor isolated, and
    /// `deinit` only runs once no other references remain, so there is no race.
    /// `AudioTap.stop()` is itself thread-safe (it tears down its own engine /
    /// Core Audio objects).
    @ObservationIgnored nonisolated(unsafe) private var previewTaps: [SourceID: AudioTap] = [:]
    /// Whether we've already requested audio-capture permission for preview this
    /// session. Once asked (and denied), we never re-prompt on every toggle —
    /// preview just stays silent until the user grants it and re-selects.
    private var previewPermissionAsked = false
    /// Sample rate captured from Settings at `startRecording` time. Every stem is
    /// resampled to this rate, and the Reaper project timeline uses it too, so a
    /// settings change mid-session can't desync stop-time export from the
    /// running taps. Defaults to 48 kHz until a recording starts.
    private var targetSampleRate: Double = Double(SettingsKeys.defaultSampleRate)
    /// Sample format captured from Settings at `startRecording` time, snapshotted
    /// alongside `targetSampleRate` so stop-time history logging records the exact
    /// format the stems were written with (a mid-session Settings change can't
    /// desync it).
    private var targetSampleFormat: SampleFormat = SettingsKeys.defaultSampleFormat
    // @ObservationIgnored + nonisolated(unsafe) so deinit can call
    // timer?.invalidate() without a main-actor hop.
    // Timer.invalidate() is documented as thread-safe from any thread.
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
    private var startDate: Date?

    /// Core Audio listener for process-object-list changes; auto-refreshes the
    /// picker when an app starts/stops producing audio. Held so it can be removed.
    @ObservationIgnored private var processListObserver: AudioObjectPropertyListenerBlock?
    /// Debounces bursts of process-list changes into a single refresh.
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init() {
        let recordings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Recordings", isDirectory: true)
        self.outputDirectory = recordings
        refreshPermissions()
    }

    deinit {
        timer?.invalidate()
        // Stop any idle-preview taps so no AVAudioEngine / Core Audio aggregate
        // device leaks when the view model is torn down (e.g. window close).
        // Safe from a nonisolated deinit: see `previewTaps`'s declaration.
        for tap in previewTaps.values { tap.stop() }
        previewTaps.removeAll()
    }

    /// Builds a filesystem-safe subfolder name for a recording start date, e.g.
    /// `2026-06-22 14-30-05`. Colons (illegal-ish on macOS, illegal elsewhere)
    /// are avoided by using `-` separators. `en_US_POSIX` + UTC-free local time
    /// keeps the format stable regardless of the user's locale.
    private static let folderNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    // MARK: - Source listing

    /// Re-enumerate tappable app sources, preserving existing selection state by
    /// bundle id. No-op while recording (source set is locked).
    ///
    /// Idle-preview reconciliation: after rebuilding the rows, stop preview taps
    /// for app sources that are no longer present, then (re)start preview for the
    /// currently-selected mic / system / app sources. This covers both the
    /// initial window appear and an explicit Refresh.
    func refreshSources() {
        guard !isRecording else { return }
        let sources = SourceCatalog.availableAppSources()
        let newIDs = Set(sources.map(\.id))
        let currentIDs = Set(appSources.map(\.id))
        // refreshSources runs on every app-activation (see RecordView). Only
        // rebuild the rows when the set of app sources actually changed —
        // reassigning unconditionally would give every AppSourceRow a fresh
        // identity each time, forcing SwiftUI to tear down and rebuild every row
        // (and its level meter) on each activation.
        if newIDs != currentIDs {
            let previouslySelected = Set(appSources.filter(\.isSelected).map(\.id))
            appSources = sources.map { source in
                let row = AppSourceRow(source: source,
                                       icon: SourceCatalog.appIcon(forBundleID: source.id))
                row.isSelected = previouslySelected.contains(source.id)
                return row
            }
        }

        // Stop preview for any app source that vanished from the list (quit app).
        // Mic/system never vanish, so only app ids are pruned here. Snapshot the
        // keys first — stopPreviewTap mutates `previewTaps`, so we must not
        // iterate the live key view while removing from it.
        let stalePreviewIDs = Array(previewTaps.keys).filter {
            $0 != SourceCatalog.microphone.id
                && $0 != SourceCatalog.systemAudio.id
                && !newIDs.contains($0)
        }
        for sourceID in stalePreviewIDs {
            stopPreviewTap(for: sourceID)
        }

        reconcilePreviewTaps()
    }

    /// (Re)start idle preview for every currently-selected source and stop preview
    /// for everything deselected. Safe to call repeatedly (start/stop are
    /// idempotent). No-op while recording — recording owns the real taps.
    func reconcilePreviewTaps() {
        guard !isRecording, !isStarting else { return }

        if micSelected {
            startMicPreviewIfNeeded()
        } else {
            stopPreviewTap(for: SourceCatalog.microphone.id, resettingLevel: { self.micLevel = 0 })
        }

        if systemSelected {
            startSystemPreviewIfNeeded()
        } else {
            stopPreviewTap(for: SourceCatalog.systemAudio.id, resettingLevel: { self.systemLevel = 0 })
        }

        for row in appSources {
            if row.isSelected {
                startAppPreviewIfNeeded(for: row)
            } else {
                stopPreviewTap(for: row.id, resettingLevel: { row.level = 0 })
            }
        }
    }

    // MARK: - Live source updates

    /// The system process-object-list property — Core Audio changes its value
    /// whenever a process gains or loses an audio object (an app starts/stops
    /// producing audio).
    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Auto-refresh the picker whenever the set of audio-producing processes
    /// changes, so the user never has to press Refresh to see an app that just
    /// started playing. Event-driven (no polling); idempotent. Call on window
    /// appear; pair with `stopObservingAudioProcesses()` on disappear.
    func startObservingAudioProcesses() {
        guard processListObserver == nil else { return }
        let observer: AudioObjectPropertyListenerBlock = { _, _ in
            // Fires on a Core Audio thread; hop to the main actor (see the
            // MeteredTap.onLevel bridge for the same pattern).
            Task { @MainActor [weak self] in self?.scheduleAutoRefresh() }
        }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, observer)
        if status == noErr { processListObserver = observer }
    }

    /// Stop the auto-refresh listener (window closed / app idle in the menu bar).
    func stopObservingAudioProcesses() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard let observer = processListObserver else { return }
        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, observer)
        processListObserver = nil
    }

    /// A single app launch can change the process list several times in a row, so
    /// collapse a burst into one refresh shortly after it settles.
    private func scheduleAutoRefresh() {
        guard !isRecording else { return }
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, !self.isRecording else { return }
            if ProcessInfo.processInfo.environment["MT_DEBUG"] != nil {
                print("[MT] audio process list changed → auto-refreshing sources")
            }
            self.refreshSources()
        }
    }

    var hasSelection: Bool {
        micSelected || systemSelected || appSources.contains(where: \.isSelected)
    }

    // MARK: - Selection toggles (drive idle preview)
    //
    // The record window mutates selection through these methods (not by writing
    // the published flags directly) so each toggle can start/stop that source's
    // idle level-preview tap. They are no-ops with respect to preview while
    // recording — the recording path owns the real taps then.

    /// Select/deselect the microphone, starting or stopping its idle preview.
    func setMicSelected(_ selected: Bool) {
        guard micSelected != selected else { return }
        micSelected = selected
        guard !isRecording else { return }
        if selected {
            guard !isStarting else { return }
            startMicPreviewIfNeeded()
        } else {
            stopPreviewTap(for: SourceCatalog.microphone.id, resettingLevel: { self.micLevel = 0 })
        }
    }

    /// Select/deselect system audio, starting or stopping its idle preview.
    func setSystemSelected(_ selected: Bool) {
        guard systemSelected != selected else { return }
        systemSelected = selected
        guard !isRecording else { return }
        if selected {
            guard !isStarting else { return }
            startSystemPreviewIfNeeded()
        } else {
            stopPreviewTap(for: SourceCatalog.systemAudio.id, resettingLevel: { self.systemLevel = 0 })
        }
    }

    /// Select/deselect an app source, starting or stopping its idle preview.
    func setAppSelected(_ row: AppSourceRow, _ selected: Bool) {
        guard row.isSelected != selected else { return }
        row.isSelected = selected
        guard !isRecording else { return }
        if selected {
            guard !isStarting else { return }
            startAppPreviewIfNeeded(for: row)
        } else {
            stopPreviewTap(for: row.id, resettingLevel: { row.level = 0 })
        }
    }

    // MARK: - Recording lifecycle

    /// Builds taps for every selected source, wires them into a
    /// `RecordingCoordinator`, and starts capture on a single shared host-time
    /// origin. Throws-free: failures are surfaced via `errorMessage`.
    ///
    /// Must be called with `Task { await model.startRecording() }` from the UI
    /// so that the audio-capture permission request runs off the main thread.
    func startRecording() async {
        guard !isRecording else { return }
        errorMessage = nil
        startWarning = nil
        lastResultSummary = nil

        guard hasSelection else {
            errorMessage = "Select at least one source to record."
            return
        }

        // Signal that we are mid-start so preview-start paths won't fire during
        // the async permission await below. Cleared on every exit path via defer,
        // except on the success path where isRecording takes over.
        isStarting = true
        // On any early exit (permission denied, build/start failure) clear the
        // flag so preview and toggles are usable again. On the success path we
        // set isRecording = true and then never enter the defer body for isStarting
        // (see the explicit clear paired with isRecording assignment below).
        defer { if !isRecording { isStarting = false } }

        // CRITICAL: stop ALL idle-preview taps BEFORE building any real recording
        // taps. Otherwise the same microphone (a second AVAudioEngine input tap)
        // or the same process/system audio (a second aggregate device) would be
        // tapped twice at once, causing device contention. This must happen up
        // front, before MicrophoneTap()/CoreAudioProcessTap() are constructed.
        stopAllPreviewTaps()

        // Capture the start instant up front: it names the per-recording folder,
        // and is the canonical timestamp logged to history at stop.
        let start = Date()

        // Snapshot Settings for this session so a mid-recording change can't
        // desync the resampling taps from the stop-time export. `targetSampleRate`
        // drives both the ResamplingTap target and the Reaper project rate;
        // `targetSampleFormat` is snapshotted so stop-time history logs the exact
        // format the stems were written with.
        let defaults = UserDefaults.standard
        let storedRate = defaults.integer(forKey: SettingsKeys.targetSampleRate)
        self.targetSampleRate = Double(storedRate > 0 ? storedRate : SettingsKeys.defaultSampleRate)
        let sampleFormat = SampleFormat(
            rawValue: defaults.string(forKey: SettingsKeys.sampleFormat) ?? "")
            ?? SettingsKeys.defaultSampleFormat
        self.targetSampleFormat = sampleFormat

        // Request audio-capture permission before building any taps. This runs
        // the blocking TCC request on a background thread (see AudioCapturePermission),
        // so the main actor (and UI) stay responsive during the system prompt.
        // Mic-only recordings don't need audio-capture permission; system audio
        // and app taps do.
        let needsAudioCapture = systemSelected || appSources.contains(where: \.isSelected)
        if needsAudioCapture {
            let ok = await AudioCapturePermission.request()
            // Refresh badges regardless of grant outcome (denied → badge updates immediately).
            refreshPermissions()
            if !ok {
                errorMessage = "System Audio Recording permission is denied. Open System Settings → Privacy & Security → Screen & System Audio Recording to grant access."
                // Recording didn't start: bring idle preview back for the meters.
                reconcilePreviewTaps()
                return
            }
        }

        // Belt-and-suspenders: stop any preview tap that may have been started
        // by a racing async Task (e.g. a preview permission grant that resumed
        // during the await above). isStarting already blocks NEW starts, but a
        // Task that captured its closure BEFORE isStarting was set could still
        // call startProcessPreviewNow. A second stopAllPreviewTaps here is cheap
        // and guarantees no preview tap is alive when we build the recording taps.
        stopAllPreviewTaps()

        // Build the underlying real taps. Each is resampled to the target rate
        // (when its native rate differs) and then wrapped in a metering
        // decorator, so all stems land at one rate (clean multitrack project).
        //
        // Per-source isolation: a source that can't be tapped (e.g. it just quit,
        // or a transient Core Audio error) is skipped and recording proceeds with
        // the rest. Only if NOTHING can be tapped do we abort.
        var metered: [MeteredTap] = []
        var skipped: [String] = []

        if micSelected {
            let mic = MicrophoneTap()
            metered.append(makeMeteredTap(for: resampledIfNeeded(mic), isMic: true))
        }

        if systemSelected {
            do {
                let tap = try CoreAudioProcessTap.systemAudio()
                metered.append(makeMeteredTap(for: resampledIfNeeded(tap), isSystem: true))
            } catch {
                skipped.append("System audio (\(describe(error)))")
            }
        }

        for row in appSources where row.isSelected {
            do {
                let tap = try CoreAudioProcessTap(forBundleID: row.source.id)
                metered.append(makeMeteredTap(for: resampledIfNeeded(tap), isMic: false, row: row))
            } catch {
                skipped.append("\(row.source.name) (\(describe(error)))")
            }
        }

        // Nothing could be tapped — surface the reasons and bail (no recording).
        guard !metered.isEmpty else {
            errorMessage = skipped.isEmpty
                ? "Couldn't start any source."
                : "Couldn't tap the selected source\(skipped.count == 1 ? "" : "s"): \(skipped.joined(separator: "; "))."
            reconcilePreviewTaps()
            return
        }

        // Some (but not all) sources were skipped — record the rest and note it.
        if !skipped.isEmpty {
            startWarning = "Recording without \(skipped.joined(separator: ", "))."
        }

        // Each recording lands in its own timestamped subfolder of the configured
        // output dir, so successive recordings never overwrite one another.
        let folderName = Self.folderNameFormatter.string(from: start)
        let recordingFolder = outputDirectory
            .appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: recordingFolder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create output folder: \(describe(error))"
            // Release the built-but-unstarted real taps, then restore preview.
            metered.forEach { $0.stop() }
            reconcilePreviewTaps()
            return
        }

        let coordinator = RecordingCoordinator(
            taps: metered, outputDirectory: recordingFolder, sampleFormat: sampleFormat)
        // CRITICAL: the recording start uses the SAME nanosecond timebase as the
        // taps' chunk stamps (HostTime). This is what zero-aligns the stems.
        do {
            try coordinator.start(startHostNanos: HostTime.nowNanos())
        } catch {
            errorMessage = "Couldn't start recording: \(describe(error))"
            metered.forEach { $0.stop() }
            reconcilePreviewTaps()
            return
        }

        // Drop an in-progress marker so a recording interrupted by a crash/quit
        // can be recovered (stem headers repaired) on next launch. Removed on a
        // clean stop.
        RecordingRecovery.writeMarker(in: recordingFolder)

        self.coordinator = coordinator
        self.meteredTaps = metered
        self.currentRecordingFolder = recordingFolder
        // Clear isStarting before setting isRecording so the defer guard
        // (`if !isRecording { isStarting = false }`) won't double-clear it —
        // isStarting is already false by the time defer runs on this path.
        self.isStarting = false
        self.isRecording = true
        self.startDate = start
        self.elapsed = 0
        startTimer()
    }

    /// Stops all taps, finalizes the WAV stems, writes the Reaper project, sets
    /// the summary, and reveals the folder in Finder.
    func stopRecording() {
        guard isRecording, let coordinator else { return }
        stopTimer()

        // The timestamped subfolder this session wrote into. Falls back to the
        // parent dir only if (impossibly) unset while recording.
        let recordingFolder = currentRecordingFolder ?? outputDirectory
        let startDate = self.startDate ?? Date()
        let elapsedAtStop = self.elapsed

        defer {
            self.coordinator = nil
            self.meteredTaps = []
            self.currentRecordingFolder = nil
            self.isRecording = false
            self.startWarning = nil
            self.micLevel = 0
            self.systemLevel = 0
            for row in appSources { row.level = 0 }
            // Recording's real taps are now torn down; bring idle preview back for
            // the currently-selected sources. `isRecording` was just set to false
            // above (same defer body), so reconcile proceeds. This restarts the
            // mic engine / aggregate devices only AFTER the recording ones stopped,
            // so two input taps never run at once.
            reconcilePreviewTaps()
        }

        // Read post-recording Settings now (rather than snapshotting at start) so
        // these purely cosmetic/output toggles reflect the user's latest choice.
        let defaults = UserDefaults.standard
        let generateReaperProject = defaults.bool(forKey: SettingsKeys.generateReaperProject)
        let revealAfterRecording = defaults.bool(forKey: SettingsKeys.revealAfterRecording)

        do {
            let result = try coordinator.stop()
            // Clean stop: clear the in-progress marker so launch recovery skips it.
            RecordingRecovery.removeMarker(in: recordingFolder)
            let stemSummary = "\(result.stems.count) stem\(result.stems.count == 1 ? "" : "s")"

            var revealTarget = recordingFolder
            if generateReaperProject {
                let projectURL = try RecordingExport.writeReaperProject(
                    for: result, in: recordingFolder, sampleRate: targetSampleRate)
                lastResultSummary = "\(stemSummary) + Reaper project"
                revealTarget = projectURL
            } else {
                lastResultSummary = stemSummary
            }

            lastOutputDirectory = recordingFolder

            // Log this recording to the persistent history. Uses the start date,
            // the elapsed clock at stop, and the snapshotted format/rate so the
            // entry matches exactly what was written to disk.
            historyStore?.add(RecordingHistoryEntry(
                date: startDate,
                durationSeconds: elapsedAtStop,
                stemCount: result.stems.count,
                folderPath: recordingFolder.path,
                sampleRate: Int(targetSampleRate),
                format: targetSampleFormat.displayName,
                stemNames: result.stems.map { $0.source.name }))

            if revealAfterRecording {
                revealInFinder(revealTarget)
            }
        } catch {
            errorMessage = "Recording finished with an error: \(describe(error))"
            lastOutputDirectory = recordingFolder
        }
    }

    /// Reveal the last output folder (or a specific file) in Finder.
    func revealInFinder(_ url: URL? = nil) {
        let target = url ?? lastOutputDirectory
        guard let target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Idle level preview
    //
    // While `!isRecording`, each selected source runs a metering-only tap that
    // drives its level meter so the user can confirm the source is live before
    // recording. These are the REAL taps (MicrophoneTap / CoreAudioProcessTap),
    // wrapped in MeteredTap, but NOT wired to a coordinator and never resampled —
    // we only read the peak level, not the audio. Tracked in `previewTaps` keyed
    // by source id.

    /// Stop ALL idle-preview taps and reset every meter to 0. Called when the
    /// record window disappears so the mic engine / aggregate devices don't keep
    /// running with no window to show them. No effect on recording (which owns
    /// its own taps); preview restarts on the next window appear / selection.
    func stopIdlePreview() {
        guard !isRecording else { return }
        stopAllPreviewTaps()
        micLevel = 0
        systemLevel = 0
        for row in appSources { row.level = 0 }
    }

    /// Stop and remove a single preview tap if one is active for `sourceID`.
    /// Idempotent (a no-op if none is running) and optionally resets the meter.
    private func stopPreviewTap(for sourceID: SourceID, resettingLevel reset: (() -> Void)? = nil) {
        if let tap = previewTaps.removeValue(forKey: sourceID) {
            tap.stop()
        }
        reset?()
    }

    /// Stop ALL active preview taps and clear the map. Used before recording
    /// starts (so the same device/process isn't tapped twice) and when stopping
    /// preview wholesale.
    private func stopAllPreviewTaps() {
        for tap in previewTaps.values { tap.stop() }
        previewTaps.removeAll()
    }

    /// Start a metering-only preview tap for the microphone if one isn't already
    /// running. AVAudioEngine triggers the mic permission prompt on first start;
    /// if the engine fails to start (e.g. denied), we just leave the meter at 0.
    private func startMicPreviewIfNeeded() {
        let id = SourceCatalog.microphone.id
        guard previewTaps[id] == nil, !isStarting else { return }
        let metered = makePreviewMeteredTap(for: MicrophoneTap()) { [weak self] level in
            self?.micLevel = level
        }
        do {
            try metered.start { _ in }
            previewTaps[id] = metered
        } catch {
            // Mic unavailable / denied: leave the meter at 0, no error banner.
            metered.stop()
            micLevel = 0
        }
    }

    /// Start a metering-only preview tap for system audio if one isn't already
    /// running. Needs the audio-capture (TCC) grant; see `startProcessPreview`.
    private func startSystemPreviewIfNeeded() {
        let id = SourceCatalog.systemAudio.id
        guard previewTaps[id] == nil, !isStarting else { return }
        startProcessPreview(id: id, make: { try CoreAudioProcessTap.systemAudio() }) {
            [weak self] level in self?.systemLevel = level
        } onZero: { [weak self] in self?.systemLevel = 0 }
    }

    /// Start a metering-only preview tap for one app source if one isn't already
    /// running. Needs the audio-capture (TCC) grant; see `startProcessPreview`.
    private func startAppPreviewIfNeeded(for row: AppSourceRow) {
        guard previewTaps[row.id] == nil, !isStarting else { return }
        startProcessPreview(id: row.id, make: { try CoreAudioProcessTap(forBundleID: row.source.id) }) {
            [weak row] level in row?.level = level
        } onZero: { [weak row] in row?.level = 0 }
    }

    /// Shared start path for app/system process preview taps, which both need the
    /// `kTCCServiceAudioCapture` grant.
    ///
    /// - If the grant is already authorized, build + start the tap immediately.
    /// - If it's denied, skip (leave the meter at 0) and never re-prompt.
    /// - If undetermined and we haven't asked yet this session, request it async
    ///   OFF the main thread (never blocking the UI); when it returns, start the
    ///   tap only if granted AND the source is still selected.
    /// The `CoreAudioProcessTap` init itself throws if TCC is denied — we catch
    /// that and silently skip for preview (no error banner).
    private func startProcessPreview(id: SourceID,
                                     make: @escaping () throws -> CoreAudioProcessTap,
                                     onLevel: @escaping @MainActor (Float) -> Void,
                                     onZero: @escaping @MainActor () -> Void) {
        switch AudioCapturePermission.current {
        case .authorized:
            startProcessPreviewNow(id: id, make: make, onLevel: onLevel, onZero: onZero)
        case .denied:
            // Don't start, don't prompt; leave the meter at 0.
            onZero()
        case .undetermined:
            guard !previewPermissionAsked else { onZero(); return }
            previewPermissionAsked = true
            Task { [weak self] in
                // Requests off the main thread (see AudioCapturePermission.request).
                let granted = await AudioCapturePermission.request()
                // Refresh permission badges regardless of outcome.
                await MainActor.run { self?.refreshPermissions() }
                guard granted else { return }
                // Only start if still idle, not starting, and the source is still
                // selected — the user may have toggled it off or hit Record during
                // the prompt. isStarting may be true if startRecording() was called
                // during the await; startProcessPreviewNow also checks it, but
                // short-circuiting here avoids the CoreAudioProcessTap construction.
                guard let self, !self.isRecording, !self.isStarting,
                      self.isStillSelected(id) else { return }
                self.startProcessPreviewNow(id: id, make: make, onLevel: onLevel, onZero: onZero)
            }
        }
    }

    /// Build + start a process preview tap right now (caller has confirmed the
    /// TCC grant). Catches any throw — including a late TCC denial inside
    /// `CoreAudioProcessTap.init` — and silently skips for preview.
    private func startProcessPreviewNow(id: SourceID,
                                        make: () throws -> CoreAudioProcessTap,
                                        onLevel: @escaping @MainActor (Float) -> Void,
                                        onZero: @escaping @MainActor () -> Void) {
        // Guard the double-start window: a prior async permission grant could race
        // a synchronous start. Whoever wins, only one tap is installed.
        // Also guard against isStarting: a previously-spawned permission Task may
        // have captured its closure before isStarting was set and now resumes here.
        guard previewTaps[id] == nil, !isStarting else { return }
        do {
            let real = try make()
            let metered = makePreviewMeteredTap(for: real, onLevel: onLevel)
            try metered.start { _ in }
            previewTaps[id] = metered
        } catch {
            // Denied/unavailable for preview: no banner, meter stays at 0.
            onZero()
        }
    }

    /// Whether a source id is still selected (used after an async permission
    /// round-trip to avoid starting a tap the user just deselected).
    private func isStillSelected(_ id: SourceID) -> Bool {
        if id == SourceCatalog.microphone.id { return micSelected }
        if id == SourceCatalog.systemAudio.id { return systemSelected }
        return appSources.contains { $0.id == id && $0.isSelected }
    }

    /// Wrap a real tap in a `MeteredTap` whose level callback hops to the main
    /// actor and is gated to the idle (preview) state, so a stray late callback
    /// after recording starts can't fight the recording meters.
    private func makePreviewMeteredTap(for tap: AudioTap,
                                       onLevel: @escaping @MainActor (Float) -> Void) -> MeteredTap {
        let metered = MeteredTap(wrapping: tap)
        metered.onLevel = { level in
            Task { @MainActor [weak self] in
                guard let self, !self.isRecording else { return }
                onLevel(level)
            }
        }
        return metered
    }

    // MARK: - Helpers

    /// Wraps a tap in a `ResamplingTap` when its native rate differs from the
    /// configured `targetSampleRate`. Taps already at the target rate (typically
    /// app/system process taps at 48 kHz) are used directly to avoid a needless
    /// conversion pass.
    private func resampledIfNeeded(_ tap: AudioTap) -> AudioTap {
        guard tap.format.sampleRate != targetSampleRate else { return tap }
        return ResamplingTap(wrapping: tap, target: targetSampleRate)
    }

    private func makeMeteredTap(for tap: AudioTap, isMic: Bool = false, isSystem: Bool = false, row: AppSourceRow? = nil) -> MeteredTap {
        let metered = MeteredTap(wrapping: tap)
        metered.onLevel = { [weak self, weak row] level in
            // Hop to the main actor before touching published state.
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if isMic {
                    self.micLevel = level
                } else if isSystem {
                    self.systemLevel = level
                } else {
                    row?.level = level
                }
            }
        }
        return metered
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func describe(_ error: Error) -> String {
        // AudioProcessListError carries a precise, user-meaningful message
        // (incl. the TCC-not-authorized explanation); prefer it.
        if let known = error as? AudioProcessListError {
            return known.description
        }
        return error.localizedDescription
    }
}
