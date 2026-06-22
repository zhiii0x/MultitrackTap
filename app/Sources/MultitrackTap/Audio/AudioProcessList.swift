import Foundation
import AudioToolbox
import AppKit
import Darwin

// Enumeration of process audio objects, adapted from AudioCap's CoreAudioUtils.swift
// by Guilherme Rambo (https://github.com/insidegui/AudioCap), BSD-2-Clause — see
// THIRD-PARTY-LICENSES.md. We keep only what we need:
// list the process audio objects, read each one's bundle id / pid, and resolve a
// bundle id or pid to an AudioObjectID we can hand to CATapDescription.

/// Lightweight, value-type description of a tappable process audio object.
struct TappableProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// Human-friendly name (localized app name when available, else process name).
    let name: String
}

enum AudioProcessListError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case notFound(String)

    var description: String {
        switch self {
        case let .coreAudio(what, status):
            return "Core Audio error (\(what)): \(status)"
        case let .notFound(query):
            return "No tappable process found for: \(query)"
        }
    }
}

// MARK: - AudioObjectID property helpers (adapted from AudioCap/CoreAudioUtils.swift)

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    var isValidObject: Bool { self != AudioObjectID(kAudioObjectUnknown) }

    /// Reads `kAudioHardwarePropertyProcessObjectList` from the system object.
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("ProcessObjectList size", err)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &ids)
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("ProcessObjectList data", err)
        }
        return ids
    }

    /// Translates a pid to its process AudioObjectID via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`.
    static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var inPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let err = withUnsafeMutablePointer(to: &inPID) { pidPtr in
            AudioObjectGetPropertyData(.system, &address, qualifierSize, pidPtr, &dataSize, &objectID)
        }
        guard err == noErr, objectID.isValidObject else {
            throw AudioProcessListError.notFound("pid \(pid)")
        }
        return objectID
    }

    /// Reads this process object's `kAudioProcessPropertyPID`.
    func readProcessPID() -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &pid)
        return err == noErr ? pid : -1
    }

    /// Reads this process object's `kAudioProcessPropertyBundleID`.
    func readProcessBundleID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }

        var cfString: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { return nil }
        let result = cfString as String
        return result.isEmpty ? nil : result
    }

    /// Reads the tap's stream format (`kAudioTapPropertyFormat`).
    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = withUnsafeMutablePointer(to: &asbd) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("kAudioTapPropertyFormat", err)
        }
        return asbd
    }

    /// Reads this (aggregate) device's INPUT-scope stream format
    /// (`kAudioDevicePropertyStreamFormat`). For a process-tap aggregate this is
    /// the rate Core Audio actually delivers buffers to the IOProc at — it
    /// follows the aggregate's main sub-device (the default OUTPUT device)
    /// nominal sample rate, which can differ from the tap's
    /// kAudioTapPropertyFormat rate (that often reports a fixed 48 kHz).
    func readInputStreamFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = withUnsafeMutablePointer(to: &asbd) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("aggregate kAudioDevicePropertyStreamFormat (input)", err)
        }
        return asbd
    }

    /// Reads a device's nominal sample rate (`kAudioDevicePropertyNominalSampleRate`).
    /// For the default OUTPUT device this is the rate a tap aggregate anchored to
    /// it actually delivers buffers at — the authoritative capture rate, and more
    /// reliable than the freshly-created aggregate's input stream format (which
    /// reports a stale default until it syncs to the sub-device).
    func readNominalSampleRate() throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let err = withUnsafeMutablePointer(to: &rate) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("kAudioDevicePropertyNominalSampleRate", err)
        }
        return rate
    }

    /// Reads `kAudioDevicePropertyDeviceUID` for a device object.
    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("kAudioDevicePropertyDeviceUID", err)
        }
        return cfString as String
    }

    /// Reads `kAudioHardwarePropertyDefaultSystemOutputDevice` from the system object.
    static func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr, deviceID.isValidObject else {
            throw AudioProcessListError.coreAudio("DefaultSystemOutputDevice", err)
        }
        return deviceID
    }
}

// MARK: - High-level enumeration / resolution

enum AudioProcessList {
    /// All process audio objects with a resolvable bundle id, deduplicated and
    /// sorted by name. Processes without a bundle id are still included so the
    /// human can see the full picture (named by pid).
    static func tappableProcesses() throws -> [TappableProcess] {
        let objectIDs = try AudioObjectID.readProcessList()
        let running = runningAppsByPID()

        var result: [TappableProcess] = []
        for objectID in objectIDs {
            let pid = objectID.readProcessPID()
            let bundleID = objectID.readProcessBundleID()
            let name = running[pid]?.name
                ?? bundleID?.components(separatedBy: ".").last
                ?? "pid \(pid)"
            result.append(TappableProcess(objectID: objectID, pid: pid, bundleID: bundleID, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a query (bundle id, or "pid:1234") to a process audio object.
    static func resolve(_ query: String) throws -> TappableProcess {
        if query.lowercased().hasPrefix("pid:") {
            let pidString = String(query.dropFirst(4))
            guard let pid = pid_t(pidString) else {
                throw AudioProcessListError.notFound(query)
            }
            let objectID = try AudioObjectID.translatePIDToProcessObject(pid)
            let processes = (try? tappableProcesses()) ?? []
            if let match = processes.first(where: { $0.objectID == objectID }) {
                return match
            }
            return TappableProcess(objectID: objectID, pid: pid,
                                   bundleID: objectID.readProcessBundleID(),
                                   name: "pid \(pid)")
        }

        // Otherwise treat the query as a bundle id.
        let processes = try tappableProcesses()
        if let match = processes.first(where: { $0.bundleID == query }) {
            return match
        }
        throw AudioProcessListError.notFound(query)
    }

    /// Resolve ALL audio-producing processes for a target bundle id.
    ///
    /// Uses three complementary matching strategies so that apps like Arc
    /// (whose audio helper has a different case in the bundle id) are still
    /// caught:
    ///
    ///   (a) Bundle-id case-insensitive exact match.
    ///   (b) Executable path is inside the target app's bundle directory
    ///       (e.g. Arc.app/Contents/Frameworks/.../Arc Helper.app/…). This
    ///       catches helpers whose bundle id bears no prefix relationship to
    ///       the parent.
    ///   (c) Fallback case-insensitive prefix match
    ///       (`targetBundleID + "."`) for Electron/Chrome-style helpers.
    ///
    /// Deduplicates by `objectID`. Returns at least one match or throws
    /// `.notFound`.
    static func resolveAll(bundleID targetBundleID: String) throws -> [TappableProcess] {
        let targetLower = targetBundleID.lowercased()
        let prefixLower = targetLower + "."

        // Collect the .app bundle directories of every running application
        // whose bundle id matches the target (case-insensitive). There may be
        // multiple instances.
        var bundleDirs: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  bid.lowercased() == targetLower,
                  let url = app.bundleURL else { continue }
            // Normalise: the bundle dir path should NOT have a trailing slash
            // so that `hasSuffix` prefixing below is reliable.
            let path = url.path
            if !bundleDirs.contains(path) {
                bundleDirs.append(path)
            }
        }

        let processes = try tappableProcesses()

        var seen = Set<AudioObjectID>()
        var matches: [TappableProcess] = []

        for proc in processes {
            let bid = proc.bundleID
            let bidLower = bid?.lowercased() ?? ""

            // (a) Exact case-insensitive bundle-id match.
            if bidLower == targetLower {
                if seen.insert(proc.objectID).inserted { matches.append(proc) }
                continue
            }

            // (b) Executable path inside any known bundle directory.
            if !bundleDirs.isEmpty {
                let execPath = executablePath(forPID: proc.pid)
                if !execPath.isEmpty {
                    for dir in bundleDirs {
                        if execPath.hasPrefix(dir + "/") {
                            if seen.insert(proc.objectID).inserted { matches.append(proc) }
                            break
                        }
                    }
                    if seen.contains(proc.objectID) { continue }
                }
            }

            // (c) Case-insensitive prefix fallback (Chrome/Electron pattern).
            if bidLower.hasPrefix(prefixLower) {
                if seen.insert(proc.objectID).inserted { matches.append(proc) }
            }
        }

        guard !matches.isEmpty else {
            throw AudioProcessListError.notFound(targetBundleID)
        }
        return matches
    }

    /// Returns the full executable path for `pid` via `proc_pidpath`,
    /// or an empty string on failure.
    ///
    /// Buffer size 4096 = 4 * MAXPATHLEN (PROC_PIDPATHINFO_MAXSIZE) — the
    /// constant is defined as a C macro and is not importable in Swift.
    static func executablePath(forPID pid: pid_t) -> String {
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let ret = proc_pidpath(pid, &buffer, UInt32(bufferSize))
        guard ret > 0 else { return "" }
        // Truncate at first null byte and decode as UTF-8.
        let validBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: validBytes, as: UTF8.self)
    }

    // MARK: - Running apps lookup

    private struct RunningApp { let name: String }

    /// Maps pid -> friendly app name using NSWorkspace, so the listing shows
    /// "Spotify" instead of a bare bundle id when possible.
    private static func runningAppsByPID() -> [pid_t: RunningApp] {
        var map: [pid_t: RunningApp] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? app.bundleIdentifier
                ?? "Unknown"
            map[app.processIdentifier] = RunningApp(name: name)
        }
        return map
    }
}
