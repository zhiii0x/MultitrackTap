import Foundation
import AudioToolbox
import AVFoundation
import MultitrackCore

// MARK: - Audio-capture (TCC) preflight
// Without a kTCCServiceAudioCapture grant, every Core Audio call below returns
// noErr but the aggregate IOProc never ticks (0 frames). Fail loudly instead.
//
// `internal` (not `private`) so the SwiftUI permission gate can call
// `AudioCaptureTCC.preflight()` before the first record.
enum AudioCaptureTCC {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn   = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// 0 = authorized, 1 = denied, anything else = unknown/never-prompted.
    static func preflight() -> Int {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return -1 }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        return fn("kTCCServiceAudioCapture" as CFString, nil)
    }

    /// Triggers the system prompt (only works inside a bundled .app with
    /// NSAudioCaptureUsageDescription). Blocks until the user answers.
    @discardableResult
    static func requestBlocking() -> Bool {
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { return false }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        let sema = DispatchSemaphore(value: 0)
        var granted = false
        fn("kTCCServiceAudioCapture" as CFString, nil) { ok in granted = ok; sema.signal() }
        sema.wait()
        return granted
    }
}

/// Taps the audio of one or more processes and delivers interleaved `[Float]` chunks
/// stamped with host-time nanoseconds.
///
/// This is adapted from AudioCap's `ProcessTap` / `ProcessTapRecorder` by
/// Guilherme Rambo (https://github.com/insidegui/AudioCap), BSD-2-Clause —
/// see THIRD-PARTY-LICENSES.md. The Core Audio sequence is:
///   1. Build a `CATapDescription(stereoMixdownOfProcesses:)` for the target(s).
///   2. `AudioHardwareCreateProcessTap` -> a tap audio object.
///   3. Read the tap's real format via `kAudioTapPropertyFormat`.
///   4. Create a private aggregate device whose tap list contains our tap,
///      anchored to the default system output device (so it auto-starts).
///   5. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` to pull buffers.
///   6. In the IOProc, interleave the float samples and stamp host nanos.
/// Teardown reverses all of this.
final class CoreAudioProcessTap: AudioTap {
    let source: Source
    private(set) var format: AudioFormat

    private let queue = DispatchQueue(label: "multitracktap.processtap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var streamDescription: AudioStreamBasicDescription
    private var onChunk: ((AudioChunk) -> Void)?
    // Bookkeeping for debug diagnostics (only emitted when MT_DEBUG is set).
    private var rawCallbackCount = 0
    private var deliveredChunkCount = 0
    private static let debugEnabled = ProcessInfo.processInfo.environment["MT_DEBUG"] != nil

    /// Picks the true buffer-delivery rate for a process-tap aggregate. The IOProc
    /// delivers at the aggregate's rate, which follows the default OUTPUT device's
    /// nominal sample rate — NOT the tap's `kAudioTapPropertyFormat` rate (often
    /// pinned at 48 kHz) nor the freshly-created aggregate's input format (which
    /// reports a stale default until it syncs). Prefer the output device's nominal
    /// rate; fall back to the aggregate input rate, then the tap rate.
    ///
    /// Getting this wrong is audible: e.g. 44.1 kHz buffers written into a 48 kHz
    /// WAV header play back ~8.7% too fast.
    static func deliveryRate(outputNominal: Double?, aggregateInput: Double?, tapRate: Double) -> Double {
        if let r = outputNominal, r > 0 { return r }
        if let r = aggregateInput, r > 0 { return r }
        return tapRate > 0 ? tapRate : 48000
    }

    /// Builds (but does not start) a process tap for the given query.
    ///
    /// If the query starts (case-insensitively) with `pid:`, it is routed
    /// through the single-process `AudioProcessList.resolve(_:)` so that
    /// a `pid:123` query works correctly.
    ///
    /// Otherwise, resolves ALL matching audio processes (main process + helpers)
    /// so that Electron/Chrome-family apps — which produce audio in helper
    /// subprocesses — are captured correctly. Prints how many processes were
    /// matched.
    convenience init(forBundleID bundleID: String) throws {
        if bundleID.lowercased().hasPrefix("pid:") {
            let process = try AudioProcessList.resolve(bundleID)
            if CoreAudioProcessTap.debugEnabled {
                print("Tapping \(bundleID) (1 process)")
            }
            try self.init(process: process, allObjectIDs: [process.objectID])
        } else {
            let processes = try AudioProcessList.resolveAll(bundleID: bundleID)
            let primaryProcess = processes[0]
            let allObjectIDs = processes.map(\.objectID)
            if CoreAudioProcessTap.debugEnabled {
                print("Tapping \(bundleID) (\(processes.count) process\(processes.count == 1 ? "" : "es"))")
            }
            try self.init(process: primaryProcess, allObjectIDs: allObjectIDs)
        }
    }

    convenience init(process: TappableProcess) throws {
        try self.init(process: process, allObjectIDs: [process.objectID])
    }

    /// Builds (but does not start) a per-process tap that mixes the given
    /// process object IDs down to stereo.
    ///
    /// Multiple object IDs capture helpers (e.g. com.google.Chrome.helper).
    convenience init(process: TappableProcess, allObjectIDs: [AudioObjectID]) throws {
        // 1. Tap description for a stereo mixdown of all matched processes.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: allObjectIDs)
        let source = Source(id: process.bundleID ?? "pid:\(process.pid)",
                            name: process.name,
                            kind: .app)
        try self.init(tapDescription: tapDescription,
                      source: source,
                      deviceLabel: "Spike-Tap-\(process.pid)")
    }

    /// Builds (but does not start) a SYSTEM-WIDE tap that captures ALL system
    /// audio, optionally excluding the given process object IDs.
    ///
    /// Uses `CATapDescription(stereoGlobalTapButExcludeProcesses:)` — the SDK's
    /// global-tap initializer (Obj-C `initStereoGlobalTapButExcludeProcesses:`,
    /// `NS_REFINED_FOR_SWIFT`). Per the CoreAudio header it "mixes all processes
    /// to a stereo stream except the given processes; all other processes that
    /// output audio are included." Passing an empty array excludes nothing, so
    /// the tap captures everything. The aggregate device, IOProc, teardown and
    /// TCC preflight are identical to the per-process path — only the
    /// CATapDescription construction differs.
    static func systemAudio(excluding excludedObjectIDs: [AudioObjectID] = []) throws -> CoreAudioProcessTap {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjectIDs)
        let source = Source(id: "system", name: "System audio", kind: .system)
        return try CoreAudioProcessTap(tapDescription: tapDescription,
                                       source: source,
                                       deviceLabel: "Spike-Tap-System")
    }

    /// Designated initializer: shared Core Audio graph for any
    /// `CATapDescription`. Validates the TCC grant, creates the tap object,
    /// reads its real format, and builds a private aggregate device anchored to
    /// the default system output device so it auto-starts.
    private init(tapDescription: CATapDescription,
                 source: Source,
                 deviceLabel: String) throws {
        // TCC preflight: if permission has been explicitly DENIED, fail loudly
        // here rather than silently getting 0 frames from the IOProc.
        // - preflight() == 0: authorized, proceed.
        // - preflight() == 1: explicitly denied, throw.
        // - anything else: unknown / never-prompted — proceed so the OS can
        //   still prompt naturally. The UI requests permission up front via
        //   AudioCapturePermission.request() before reaching this point.
        let tcc = AudioCaptureTCC.preflight()
        if tcc == 1 {
            throw AudioProcessListError.coreAudio(
                "kTCCServiceAudioCapture is denied (preflight=\(tcc)). Grant System Audio Recording permission in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.",
                OSStatus(tcc))
        }

        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        // 2. Create the process tap object.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr else {
            throw AudioProcessListError.coreAudio("AudioHardwareCreateProcessTap", err)
        }
        self.tapID = newTapID

        // 3. Read the tap's real format (sample rate + channel count) and expose
        //    it through MultitrackCore's AudioFormat.
        let asbd = try newTapID.readTapStreamDescription()
        self.streamDescription = asbd
        let reportedChannels = asbd.mChannelsPerFrame == 0 ? 2 : Int(asbd.mChannelsPerFrame)
        self.format = AudioFormat(
            sampleRate: asbd.mSampleRate == 0 ? 48000 : asbd.mSampleRate,
            channelCount: reportedChannels
        )

        self.source = source

        // 4. Build a private aggregate device that hosts the tap, anchored to the
        //    current default system output device so it auto-starts.
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceLabel,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            // Best-effort cleanup of the already-created tap before bailing.
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioProcessListError.coreAudio("AudioHardwareCreateAggregateDevice", err)
        }
        self.aggregateDeviceID = newAggregateID

        // CRITICAL: the IOProc delivers at the AGGREGATE DEVICE's rate, which
        // follows the default OUTPUT device's nominal sample rate — NOT the tap's
        // kAudioTapPropertyFormat rate (that can report a fixed 48 kHz while the
        // output device runs at 44.1/96 kHz). Reading the freshly-created
        // aggregate's input stream format is unreliable (it reports a stale
        // default until it syncs to the sub-device), so take the rate
        // authoritatively from the OUTPUT device's nominal sample rate. If the WAV
        // header used a rate different from the delivered one, playback speed would
        // be wrong (e.g. 44.1k buffers in a 48k file play ~8.7% too fast). Reporting
        // the true rate also lets the downstream ResamplingTap convert to the
        // project rate. Channel count stays from the tap's stereo-mixdown format.
        let tapRate = self.format.sampleRate
        let outputNominal = try? systemOutputID.readNominalSampleRate()
        let aggregateInput = (try? newAggregateID.readInputStreamFormat())?.mSampleRate
        let deliveredRate = Self.deliveryRate(
            outputNominal: outputNominal, aggregateInput: aggregateInput, tapRate: tapRate)
        self.format = AudioFormat(sampleRate: deliveredRate, channelCount: self.format.channelCount)
        self.streamDescription.mSampleRate = deliveredRate
        if CoreAudioProcessTap.debugEnabled {
            try? FileHandle.standardError.write(contentsOf: Data(
                "[tap] rate: tapFormat=\(tapRate) outputNominal=\(outputNominal ?? -1) aggregateInput=\(aggregateInput ?? -1) -> using \(deliveredRate) Hz\n".utf8))
        }
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        self.onChunk = onChunk

        // 5. Install an IOProc and start the aggregate device.
        var newProcID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, queue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handle(inputData: inInputData, inputTime: inInputTime)
        }
        guard err == noErr, let procID = newProcID else {
            throw AudioProcessListError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", err)
        }
        self.deviceProcID = procID

        err = AudioDeviceStart(aggregateDeviceID, procID)
        guard err == noErr else {
            // AudioDeviceStart failed: destroy the IOProc we just created so no
            // orphaned IOProc leaks alongside the aggregate device.
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
            throw AudioProcessListError.coreAudio("AudioDeviceStart", err)
        }
    }

    private func handle(inputData: UnsafePointer<AudioBufferList>,
                        inputTime: UnsafePointer<AudioTimeStamp>) {
        guard let onChunk else { return }

        rawCallbackCount += 1
        if CoreAudioProcessTap.debugEnabled && rawCallbackCount == 1 {
            let abl0 = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let nb = abl0.count
            let ch0 = abl0.first.map { Int($0.mNumberChannels) } ?? -1
            let bytes0 = abl0.first.map { Int($0.mDataByteSize) } ?? -1
            try? FileHandle.standardError.write(contentsOf: Data("[tap] first IOProc callback: \(nb) buffer(s), \(ch0) ch, \(bytes0) bytes\n".utf8))
        }

        // Host time of the first sample in this IOProc callback, through the
        // shared timebase. mHostTime is in the same tick units as
        // mach_absolute_time() and AVAudioTime.hostTime.
        let ts = inputTime.pointee
        let hostNanos: UInt64
        if ts.mFlags.contains(.hostTimeValid) {
            hostNanos = HostTime.nanos(fromHostTime: ts.mHostTime)
        } else {
            hostNanos = HostTime.nowNanos()
        }

        let ablPointer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let firstBuffer = ablPointer.first else { return }

        let channelCount = Int(firstBuffer.mNumberChannels)
        guard channelCount > 0 else { return }

        // The tap delivers 32-bit float. It is typically a single interleaved
        // buffer (one AudioBuffer with mNumberChannels == channels), matching the
        // stereo mixdown we requested. Handle both interleaved (1 buffer) and
        // deinterleaved (N buffers) layouts defensively.
        if ablPointer.count == 1 {
            // Interleaved: copy straight through.
            let byteCount = Int(firstBuffer.mDataByteSize)
            let sampleCount = byteCount / MemoryLayout<Float>.size
            guard sampleCount > 0, let data = firstBuffer.mData else { return }
            let src = data.assumingMemoryBound(to: Float.self)
            let samples = Array(UnsafeBufferPointer(start: src, count: sampleCount))
            deliveredChunkCount += 1
            onChunk(AudioChunk(hostNanos: hostNanos, samples: samples))
        } else {
            // Deinterleaved: one mono buffer per channel; interleave them.
            let buffers = Array(ablPointer)
            let perChannelFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            guard perChannelFrames > 0 else { return }
            let outChannels = buffers.count
            var interleaved = [Float](repeating: 0, count: perChannelFrames * outChannels)
            for (ch, buf) in buffers.enumerated() {
                guard let data = buf.mData else { continue }
                let src = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<perChannelFrames {
                    interleaved[frame * outChannels + ch] = src[frame]
                }
            }
            deliveredChunkCount += 1
            onChunk(AudioChunk(hostNanos: hostNanos, samples: interleaved))
        }
    }

    func stop() {
        onChunk = nil

        // 6. Tear down in reverse order: stop + destroy IOProc, destroy aggregate
        //    device, destroy the tap.
        if aggregateDeviceID.isValidObject {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID.isValidObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if CoreAudioProcessTap.debugEnabled {
            if rawCallbackCount > 0 || deliveredChunkCount > 0 {
                try? FileHandle.standardError.write(contentsOf: Data("[tap] IOProc fired \(rawCallbackCount)x, delivered \(deliveredChunkCount) chunks\n".utf8))
            } else {
                try? FileHandle.standardError.write(contentsOf: Data("[tap] IOProc NEVER fired (0 callbacks) — aggregate device didn't tick or audio capture was blocked\n".utf8))
            }
        }
    }

    deinit { stop() }
}
