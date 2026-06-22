import Foundation

/// A source of interleaved float PCM. Real implementations live in the app
/// target (Core Audio process tap, mic). `FakeTap` drives unit tests.
public protocol AudioTap: AnyObject {
    var source: Source { get }
    var format: AudioFormat { get }
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
}

/// Deterministic test double: emits its chunks synchronously when started.
/// Pass `startError` to simulate a source that fails to start.
public final class FakeTap: AudioTap {
    public let source: Source
    public let format: AudioFormat
    private let chunks: [AudioChunk]
    private let startError: Error?

    public init(source: Source, format: AudioFormat = .standard,
                chunks: [AudioChunk] = [], startError: Error? = nil) {
        self.source = source
        self.format = format
        self.chunks = chunks
        self.startError = startError
    }

    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        if let startError { throw startError }
        for chunk in chunks { onChunk(chunk) }
    }

    public func stop() {}
}
