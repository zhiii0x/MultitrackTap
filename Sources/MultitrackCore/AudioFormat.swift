public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public static let standard = AudioFormat(sampleRate: 48000, channelCount: 2)
}
