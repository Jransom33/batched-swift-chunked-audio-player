import Foundation

public struct AudioStreamChunk: Sendable {
    public let data: Data
    public let trim: AudioStreamChunkTrim?

    public init(data: Data, trim: AudioStreamChunkTrim? = nil) {
        self.data = data
        self.trim = trim
    }
}

public struct AudioStreamChunkTrim: Sendable {
    /// Optional sample rate hint in Hz. When missing, the receiver relies on the stream format.
    public let sampleRateHz: Double?
    /// Number of leading PCM frames to discard from the decoded output of this chunk.
    public let leadingFrames: Int
    /// Number of trailing PCM frames to discard from the decoded output of this chunk.
    public let trailingFrames: Int
    /// Total PCM frames contained in this chunk prior to trimming (including leading/trailing).
    public let totalFrames: Int?

    public init(sampleRateHz: Double?, leadingFrames: Int, trailingFrames: Int, totalFrames: Int? = nil) {
        self.sampleRateHz = sampleRateHz
        self.leadingFrames = leadingFrames
        self.trailingFrames = trailingFrames
        self.totalFrames = totalFrames
    }
}
