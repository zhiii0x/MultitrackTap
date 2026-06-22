/// One delivery of interleaved float PCM from a tap, stamped with the host
/// time (in nanoseconds) of its first sample.
public struct AudioChunk: Equatable, Sendable {
    public let hostNanos: UInt64
    public let samples: [Float]   // interleaved by channel

    public init(hostNanos: UInt64, samples: [Float]) {
        self.hostNanos = hostNanos
        self.samples = samples
    }
}
