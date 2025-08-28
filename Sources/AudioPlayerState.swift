public enum AudioPlayerState: Equatable, Sendable {
    case initial
    case playing
    case paused
    case buffering
    case completed
    case failed
}
