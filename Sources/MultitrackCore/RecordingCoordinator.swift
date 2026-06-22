import Foundation

public struct RecordedStem: Equatable, Sendable {
    public let source: Source
    public let url: URL
    public let frameCount: Int
}

public struct RecordingResult: Equatable, Sendable {
    public let stems: [RecordedStem]
    public init(stems: [RecordedStem]) { self.stems = stems }
}

public enum RecordingCoordinatorError: Error {
    /// Every selected source failed to start, so there is nothing to record.
    case noSourcesStarted
}

/// Orchestrates a set of taps: one WAVWriter per tap, prepends leading silence
/// on each tap's first chunk so every stem starts at the recording start,
/// periodically rewrites each header for crash-safety, then finalizes all files.
///
/// A single source that can't be built or started is isolated — it is dropped
/// and the remaining sources keep recording. The whole recording only fails if
/// *no* source could start.
public final class RecordingCoordinator {
    private let taps: [AudioTap]
    private let outputDirectory: URL
    private let sampleFormat: SampleFormat
    private let headerFlushFrames: Int

    private var writers: [ObjectIdentifier: WAVWriter] = [:]
    private var sources: [ObjectIdentifier: Source] = [:]
    private var frameCounts: [ObjectIdentifier: Int] = [:]
    private var framesSinceFlush: [ObjectIdentifier: Int] = [:]
    private var seenFirstChunk: Set<ObjectIdentifier> = []
    private var usedFileNames: Set<String> = []
    private var startHostNanos: UInt64 = 0
    private var firstError: Error?
    private let lock = NSLock()

    /// - Parameter headerFlushFrames: how many frames a source writes before its
    ///   WAV header is rewritten in place (crash-safety). ~1 second by default;
    ///   lower values flush more often.
    public init(taps: [AudioTap], outputDirectory: URL,
                sampleFormat: SampleFormat = .float32,
                headerFlushFrames: Int = 48_000) {
        self.taps = taps
        self.outputDirectory = outputDirectory
        self.sampleFormat = sampleFormat
        self.headerFlushFrames = max(1, headerFlushFrames)
    }

    public func start(startHostNanos: UInt64) throws {
        self.startHostNanos = startHostNanos

        // Phase 1: build a writer per tap, isolating per-source construction
        // failures — one source that can't be written must not abort the rest.
        var newWriters: [ObjectIdentifier: WAVWriter] = [:]
        var newSources: [ObjectIdentifier: Source] = [:]
        var newFrameCounts: [ObjectIdentifier: Int] = [:]
        var newUsedFileNames: Set<String> = []
        var built: [AudioTap] = []
        var startFailure: Error?

        for tap in taps {
            let key = ObjectIdentifier(tap)
            let fileName = SourceNaming.fileName(for: tap.source, existing: newUsedFileNames)
            let url = outputDirectory.appendingPathComponent(fileName)
            do {
                let writer = try WAVWriter(url: url, format: tap.format, sampleFormat: sampleFormat)
                newUsedFileNames.insert(fileName)
                newWriters[key] = writer
                newSources[key] = tap.source
                newFrameCounts[key] = 0
                built.append(tap)
            } catch {
                if startFailure == nil { startFailure = error }
            }
        }

        // Phase 2: commit state under lock, before any callback can fire.
        lock.lock()
        writers = newWriters
        sources = newSources
        frameCounts = newFrameCounts
        framesSinceFlush = [:]
        usedFileNames = newUsedFileNames
        lock.unlock()

        // Phase 3: start each tap, isolating per-source start failures. A tap
        // that fails to start is dropped (its empty stem file removed); the rest
        // keep recording.
        for tap in built {
            let key = ObjectIdentifier(tap)
            do {
                try tap.start { [weak self] chunk in
                    self?.handle(key: key, format: tap.format, chunk: chunk)
                }
            } catch {
                if startFailure == nil { startFailure = error }
                lock.lock()
                let writer = writers.removeValue(forKey: key)
                sources.removeValue(forKey: key)
                frameCounts.removeValue(forKey: key)
                lock.unlock()
                if let writer {
                    try? writer.finalize()
                    try? FileManager.default.removeItem(at: writer.url)
                }
            }
        }

        // Only fail the whole recording if nothing could be started.
        lock.lock(); let active = writers.count; lock.unlock()
        if active == 0 { throw startFailure ?? RecordingCoordinatorError.noSourcesStarted }
    }

    private func handle(key: ObjectIdentifier, format: AudioFormat, chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        guard let writer = writers[key] else { return }
        do {
            if !seenFirstChunk.contains(key) {
                seenFirstChunk.insert(key)
                let pad = TimelineAligner.leadingSilenceFrames(
                    startHostNanos: startHostNanos,
                    firstSampleHostNanos: chunk.hostNanos,
                    sampleRate: format.sampleRate)
                if pad > 0 {
                    try writer.append([Float](repeating: 0, count: pad * format.channelCount))
                    frameCounts[key, default: 0] += pad
                    framesSinceFlush[key, default: 0] += pad
                }
            }
            try writer.append(chunk.samples)
            let frames = chunk.samples.count / max(1, format.channelCount)
            frameCounts[key, default: 0] += frames
            framesSinceFlush[key, default: 0] += frames

            // Crash-safety: periodically rewrite the header in place so an
            // interrupted recording stays a valid, playable WAV up to here.
            if framesSinceFlush[key, default: 0] >= headerFlushFrames {
                try writer.flushHeader()
                framesSinceFlush[key] = 0
            }
        } catch {
            if firstError == nil { firstError = error }
        }
    }

    public func stop() throws -> RecordingResult {
        for tap in taps { tap.stop() }
        var stems: [RecordedStem] = []
        lock.lock()
        defer { lock.unlock() }
        for tap in taps {
            let key = ObjectIdentifier(tap)
            guard let writer = writers[key], let source = sources[key] else { continue }
            try writer.finalize()
            stems.append(RecordedStem(source: source, url: writer.url,
                                      frameCount: frameCounts[key] ?? 0))
        }
        if let err = firstError { throw err }
        return RecordingResult(stems: stems)
    }
}
