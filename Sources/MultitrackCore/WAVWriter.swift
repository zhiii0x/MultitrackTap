import Foundation

public enum WAVWriterError: Error, Equatable {
    case recordingTooLarge
}

/// Streaming writer for interleaved WAV in a configurable sample format
/// (16-/24-bit PCM or 32-bit IEEE float). Writes a placeholder header, appends
/// samples, then rewrites the header with final sizes on `finalize()`. Header is
/// always 44 bytes.
public final class WAVWriter {
    public let url: URL
    private let format: AudioFormat
    private let sampleFormat: SampleFormat
    private let handle: FileHandle
    private var sampleCount: Int = 0   // total interleaved samples written

    public init(url: URL, format: AudioFormat, sampleFormat: SampleFormat = .float32) throws {
        self.url = url
        self.format = format
        self.sampleFormat = sampleFormat
        FileManager.default.createFile(atPath: url.path, contents: Data())
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: try Self.header(format: format, sampleFormat: sampleFormat, sampleCount: 0))
    }

    deinit {
        try? handle.close()
    }

    public func append(_ samples: [Float]) throws {
        let bytesPerSample = sampleFormat.bytesPerSample
        var data = Data(capacity: samples.count * bytesPerSample)
        switch sampleFormat {
        case .float32:
            for sample in samples {
                var le = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        case .int16:
            for sample in samples {
                let clamped = min(1, max(-1, sample))
                let value = Int16(truncatingIfNeeded: Int(round(clamped * 32767)))
                var le = UInt16(bitPattern: value).littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        case .int24:
            for sample in samples {
                let clamped = min(1, max(-1, sample))
                let value = Int32(round(clamped * 8388607))  // 2^23 - 1
                // Little-endian 3-byte signed: low, mid, high.
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(truncatingIfNeeded: value >> 8))
                data.append(UInt8(truncatingIfNeeded: value >> 16))
            }
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    public func finalize() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: try Self.header(format: format, sampleFormat: sampleFormat, sampleCount: sampleCount))
        try handle.close()
    }

    /// Rewrites the header in place with the current sizes, then returns the
    /// write cursor to the end of the file — WITHOUT closing. Called periodically
    /// while recording so that if the app is interrupted before `finalize()`, the
    /// file on disk is still a valid, playable WAV up to the last flush.
    public func flushHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: try Self.header(
            format: format, sampleFormat: sampleFormat, sampleCount: sampleCount))
        try handle.seek(toOffset: end)
    }

    /// Repairs a WAV file whose RIFF/data sizes are stale — e.g. a recording
    /// interrupted before `finalize()` ran. Rewrites the two size fields from the
    /// actual on-disk byte count (rounded down to whole frames using the file's
    /// own `blockAlign`). Returns `true` if the header changed, `false` if it was
    /// already correct or there is nothing to recover. Idempotent.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 44 else { return false }          // header only — nothing to recover
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: 44), head.count == 44 else { return false }
        let blockAlign = max(1, Int(head[32]) | (Int(head[33]) << 8))
        let raw = Int(size) - 44
        let dataSize = raw - (raw % blockAlign)        // keep only whole frames
        let current = Int(head[40]) | Int(head[41]) << 8 | Int(head[42]) << 16 | Int(head[43]) << 24
        guard dataSize >= 0, dataSize <= Int(UInt32.max) - 36, dataSize != current else { return false }
        var riff = Data(); riff.appendU32(UInt32(36 + dataSize))
        var data = Data(); data.appendU32(UInt32(dataSize))
        try handle.seek(toOffset: 4);  try handle.write(contentsOf: riff)
        try handle.seek(toOffset: 40); try handle.write(contentsOf: data)
        return true
    }

    /// Returns the RIFF chunk size for a hypothetical recording.
    /// Throws `WAVWriterError.recordingTooLarge` if the size would overflow UInt32.
    public static func riffChunkSize(sampleCount: Int, channelCount: Int,
                                     sampleFormat: SampleFormat = .float32) throws -> UInt32 {
        let bytesPerSample = sampleFormat.bytesPerSample
        let dataSize = sampleCount * channelCount * bytesPerSample
        guard dataSize <= Int(UInt32.max) - 36 else { throw WAVWriterError.recordingTooLarge }
        return UInt32(36 + dataSize)
    }

    static func header(format: AudioFormat, sampleFormat: SampleFormat, sampleCount: Int) throws -> Data {
        let bytesPerSample = sampleFormat.bytesPerSample
        let channels = format.channelCount
        let dataSize = sampleCount * bytesPerSample
        guard dataSize <= Int(UInt32.max) - 36 else { throw WAVWriterError.recordingTooLarge }
        let byteRate = Int(format.sampleRate) * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var d = Data()
        d.appendASCII("RIFF")
        d.appendU32(UInt32(36 + dataSize))
        d.appendASCII("WAVE")
        d.appendASCII("fmt ")
        d.appendU32(16)
        d.appendU16(sampleFormat.waveFormatTag)        // 1 = PCM, 3 = IEEE float
        d.appendU16(UInt16(channels))
        d.appendU32(UInt32(format.sampleRate))
        d.appendU32(UInt32(byteRate))
        d.appendU16(UInt16(blockAlign))
        d.appendU16(UInt16(bytesPerSample * 8))        // bits per sample
        d.appendASCII("data")
        d.appendU32(UInt32(dataSize))
        return d
    }
}

private extension SampleFormat {
    var bytesPerSample: Int {
        switch self {
        case .int16: return 2
        case .int24: return 3
        case .float32: return 4
        }
    }

    var waveFormatTag: UInt16 {
        switch self {
        case .int16, .int24: return 1   // PCM
        case .float32: return 3         // IEEE float
        }
    }
}

private extension Data {
    mutating func appendASCII(_ s: String) { append(contentsOf: Array(s.utf8)) }
    mutating func appendU32(_ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
    mutating func appendU16(_ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
}
