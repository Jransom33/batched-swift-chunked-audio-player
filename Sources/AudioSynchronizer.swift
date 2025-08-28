import AVFoundation
import AudioToolbox
import Combine

final class AudioSynchronizer: Sendable {
    typealias RateCallback = @Sendable (_ time: Float) -> Void
    typealias TimeCallback = @Sendable (_ time: CMTime) -> Void
    typealias DurationCallback = @Sendable (_ duration: CMTime) -> Void
    typealias ErrorCallback = @Sendable (_ error: AudioPlayerError?) -> Void
    typealias CompleteCallback = @Sendable () -> Void
    typealias PlayingCallback = @Sendable () -> Void
    typealias PausedCallback = @Sendable () -> Void
    typealias SampleBufferCallback = @Sendable (CMSampleBuffer?) -> Void
    typealias BufferingCallback = @Sendable () -> Void

    private let queue = DispatchQueue(label: "audio.player.queue")
    private let onRateChanged: RateCallback
    private let onTimeChanged: TimeCallback
    private let onDurationChanged: DurationCallback
    private let onError: ErrorCallback
    private let onComplete: CompleteCallback
    private let onPlaying: PlayingCallback
    private let onPaused: PausedCallback
    private let onSampleBufferChanged: SampleBufferCallback
    private let onBuffering: BufferingCallback
    private let timeUpdateInterval: CMTime
    private let initialVolume: Float

    private nonisolated(unsafe) var receiveComplete = false
    private nonisolated(unsafe) var audioBuffersQueue: AudioBuffersQueue?
    private nonisolated(unsafe) var audioFileStream: AudioFileStream?
    private nonisolated(unsafe) var audioRenderer: AVSampleBufferAudioRenderer?
    private nonisolated(unsafe) var audioSynchronizer: AVSampleBufferRenderSynchronizer?
    private nonisolated(unsafe) var currentSampleBufferTime: CMTime?
    private nonisolated(unsafe) var isBuffering = false

    private nonisolated(unsafe) var audioRendererErrorCancellable: AnyCancellable?
    private nonisolated(unsafe) var audioRendererRateCancellable: AnyCancellable?
    private nonisolated(unsafe) var audioRendererTimeCancellable: AnyCancellable?

    nonisolated(unsafe) var desiredRate: Float = 1.0 {
        didSet {
            if desiredRate == 0.0 {
                pause()
            } else {
                resume(at: desiredRate)
            }
        }
    }

    var volume: Float {
        get { audioRenderer?.volume ?? initialVolume }
        set { audioRenderer?.volume = newValue }
    }

    var isMuted: Bool {
        get { audioRenderer?.isMuted ?? false }
        set { audioRenderer?.isMuted = newValue }
    }

    init(
        timeUpdateInterval: CMTime,
        initialVolume: Float = 1.0,
        onRateChanged: @escaping RateCallback = { _ in },
        onTimeChanged: @escaping TimeCallback = { _ in },
        onDurationChanged: @escaping DurationCallback = { _ in },
        onError: @escaping ErrorCallback = { _ in },
        onComplete: @escaping CompleteCallback = {},
        onPlaying: @escaping PlayingCallback = {},
        onPaused: @escaping PausedCallback = {},
        onSampleBufferChanged: @escaping SampleBufferCallback = { _ in },
        onBuffering: @escaping BufferingCallback = {}
    ) {
        self.timeUpdateInterval = timeUpdateInterval
        self.initialVolume = initialVolume
        self.onRateChanged = onRateChanged
        self.onTimeChanged = onTimeChanged
        self.onDurationChanged = onDurationChanged
        self.onError = onError
        self.onComplete = onComplete
        self.onPlaying = onPlaying
        self.onPaused = onPaused
        self.onSampleBufferChanged = onSampleBufferChanged
        self.onBuffering = onBuffering
    }

    func prepare(type: AudioFileTypeID? = nil) {
        invalidate()
        audioFileStream = AudioFileStream(type: type, queue: queue) { [weak self] error in
            self?.onError(error)
        } receiveASBD: { [weak self] asbd in
            self?.onFileStreamDescriptionReceived(asbd: asbd)
        } receivePackets: { [weak self] numberOfBytes, bytes, numberOfPackets, packets in
            self?.onFileStreamPacketsReceived(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
        }
        audioFileStream?.open()
    }

    func pause() {
        guard let audioSynchronizer, audioSynchronizer.rate != 0.0 else { return }
        audioSynchronizer.rate = 0.0
        onPaused()
    }

    func resume(at rate: Float? = nil) {
        guard let audioSynchronizer else { return }
        let oldRate = audioSynchronizer.rate
        let newRate = rate ?? desiredRate
        guard audioSynchronizer.rate != newRate else { return }
        audioSynchronizer.rate = newRate
        if oldRate == 0.0 && newRate > 0.0 {
            onPlaying()
        }
    }

    func rewind(_ time: CMTime) {
        guard let audioSynchronizer else { return }
        seek(to: audioSynchronizer.currentTime() - time)
    }

    func forward(_ time: CMTime) {
        guard let audioSynchronizer else { return }
        seek(to: audioSynchronizer.currentTime() + time)
    }

    func seek(to time: CMTime) {
        guard let audioSynchronizer, let audioRenderer, let audioBuffersQueue else { return }
        let range = CMTimeRange(start: .zero, duration: audioBuffersQueue.duration)
        let clampedTime = time.clamped(to: range)
        let currentRate = audioSynchronizer.rate
        audioSynchronizer.rate = 0.0
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioBuffersQueue.flush()
        audioBuffersQueue.seek(to: clampedTime)
        restartRequestingMediaData(audioRenderer, from: clampedTime, rate: currentRate)
    }

    func receive(data: Data) {
        audioFileStream?.parseData(data)
    }

    func finish() {
        audioFileStream?.finishDataParsing()
        receiveComplete = true
    }

    func invalidate(_ completion: @escaping @Sendable () -> Void = {}) {
        removeBuffers()
        closeFileStream()
        cancelObservation()
        receiveComplete = false
        currentSampleBufferTime = nil
        onSampleBufferChanged(nil)
        if let audioSynchronizer, let audioRenderer {
            audioRenderer.stopRequestingMediaData()
            audioSynchronizer.removeRenderer(audioRenderer, at: .zero) { [weak self] _ in
                self?.audioRenderer = nil
                self?.audioSynchronizer = nil
                completion()
            }
        } else {
            audioRenderer = nil
            audioSynchronizer = nil
            completion()
        }
    }

    // MARK: - Private

    private func onFileStreamDescriptionReceived(asbd: AudioStreamBasicDescription) {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = initialVolume
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        audioBuffersQueue = AudioBuffersQueue(audioDescription: asbd)
        observeRenderer(renderer, synchronizer: synchronizer)
        startRequestingMediaData(renderer)
    }

    private func onFileStreamPacketsReceived(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        do {
            guard let audioBuffersQueue else { return }
            try audioBuffersQueue.enqueue(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
        } catch {
            onError(AudioPlayerError(error: error))
        }
    }

    private func startRequestingMediaData(_ renderer: AVSampleBufferAudioRenderer) {
        nonisolated(unsafe) var didStart = false
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, let audioRenderer, let audioBuffersQueue else { return }
            var enqueuedAny = false
            while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                audioRenderer.enqueue(buffer)
                audioBuffersQueue.removeFirst()
                onDurationChanged(audioBuffersQueue.duration)
                enqueuedAny = true
                startPlaybackIfNeeded(didStart: &didStart)
            }
            startPlaybackIfNeeded(didStart: &didStart)

            if !enqueuedAny,
               audioRenderer.isReadyForMoreMediaData,
               !(receiveComplete && (audioFileStream?.parsingComplete == true))
            {
                if !isBuffering { isBuffering = true; onBuffering() }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    // Also try force exit method as backup
                    forceExitBufferingIfPossible()
                }
            }

            stopRequestingMediaDataIfNeeded()
        }
    }

    private func restartRequestingMediaData(_ renderer: AVSampleBufferAudioRenderer, from time: CMTime, rate: Float) {
        nonisolated(unsafe) var didStart = false
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, let audioRenderer, let audioSynchronizer, let audioBuffersQueue else { return }
            var enqueuedAny = false
            while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                audioRenderer.enqueue(buffer)
                audioBuffersQueue.removeFirst()
                onDurationChanged(audioBuffersQueue.duration)
                enqueuedAny = true
            }
            if !didStart {
                audioSynchronizer.setRate(rate, time: time)
                didStart = true
            }

            if !enqueuedAny,
               audioRenderer.isReadyForMoreMediaData,
               !(receiveComplete && (audioFileStream?.parsingComplete == true))
            {
                if !isBuffering { isBuffering = true; onBuffering() }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    // Also try force exit method as backup
                    forceExitBufferingIfPossible()
                }
            }

            stopRequestingMediaDataIfNeeded()
        }
    }

    private func startPlaybackIfNeeded(didStart: inout Bool) {
        guard let audioRenderer,
              let audioSynchronizer,
              let audioFileStream,
              audioSynchronizer.rate == 0,
              !didStart else { return }
        let dataComplete = receiveComplete && audioFileStream.parsingComplete
        let shouldStart = audioRenderer.hasSufficientMediaDataForReliablePlaybackStart || dataComplete
        guard shouldStart else { return }
        audioSynchronizer.setRate(desiredRate, time: .zero)
        didStart = true
        isBuffering = false
        onPlaying()
    }
    
    private func forceExitBufferingIfPossible() {
        guard isBuffering,
              let audioRenderer = self.audioRenderer,
              let audioSynchronizer = self.audioSynchronizer,
              let audioBuffersQueue = self.audioBuffersQueue else { return }
        
        // Check if we have any buffers available or sufficient media data
        let hasBuffers = !audioBuffersQueue.isEmpty
        let hasSufficientData = audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
        
        if hasBuffers || hasSufficientData {
            print("🚑 [FORCE_EXIT_BUFFERING] Forcing exit from buffering - hasBuffers: \(hasBuffers), hasSufficientData: \(hasSufficientData)")
            isBuffering = false
            
            // Restart media data requests
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                // This will re-trigger the normal media request logic
                self.handleMediaDataRequest(renderer: audioRenderer, synchronizer: audioSynchronizer)
            }
        }
    }
    
    private func handleMediaDataRequest(renderer: AVSampleBufferAudioRenderer, synchronizer: AVSampleBufferRenderSynchronizer) {
        guard let audioBuffersQueue = self.audioBuffersQueue else { return }
        
        var enqueuedAny = false
        while let buffer = audioBuffersQueue.peek(), renderer.isReadyForMoreMediaData {
            renderer.enqueue(buffer)
            audioBuffersQueue.removeFirst()
            onDurationChanged(audioBuffersQueue.duration)
            enqueuedAny = true
        }
        
        // If we successfully enqueued data and synchronizer is stopped, start it
        if enqueuedAny && synchronizer.rate == 0 {
            synchronizer.setRate(desiredRate, time: synchronizer.currentTime())
            isBuffering = false
            onPlaying()
        }
    }

    private func stopRequestingMediaDataIfNeeded() {
        guard let audioRenderer, let audioBuffersQueue, let audioFileStream else { return }
        if audioBuffersQueue.isEmpty,
           receiveComplete,
           audioFileStream.parsingComplete
        {
            audioRenderer.stopRequestingMediaData()
        }
    }

    private func closeFileStream() {
        audioFileStream?.close()
        audioFileStream = nil
    }

    private func removeBuffers() {
        audioBuffersQueue?.removeAll()
        audioBuffersQueue = nil
        audioRenderer?.flush()
    }

    private func observeRenderer(
        _ renderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer
    ) {
        observeRate(synchronizer)
        observeTime(renderer)
        observeError(renderer)
    }

    private func cancelObservation() {
        cancelRateObservation()
        cancelTimeObservation()
        cancelErrorObservation()
    }

    private func observeRate(_ audioSynchronizer: AVSampleBufferRenderSynchronizer) {
        cancelRateObservation()
        let name = AVSampleBufferRenderSynchronizer.rateDidChangeNotification
        audioRendererRateCancellable = NotificationCenter.default
            .publisher(for: name).sink { [weak self, weak audioSynchronizer] _ in
                guard let self, let audioSynchronizer else { return }
                onRateChanged(audioSynchronizer.rate)
            }
    }

    private func cancelRateObservation() {
        audioRendererRateCancellable?.cancel()
        audioRendererRateCancellable = nil
    }

    private func observeTime(_ audioRenderer: AVSampleBufferAudioRenderer) {
        cancelTimeObservation()
        audioRendererTimeCancellable = audioSynchronizer?.periodicTimeObserver(
            interval: timeUpdateInterval,
            queue: queue
        ).sink { [weak self] time in
            guard let self else { return }
            updateCurrentBufferIfNeeded(at: time)

            let epsilon = CMTime(value: 1, timescale: 1000) // tiny tolerance (~1 ms) to avoid float/tick jitter

            if let audioBuffersQueue,
               let audioSynchronizer,
               time + epsilon >= audioBuffersQueue.duration
            {
                // We caught up to the buffered end. Decide: buffering vs EOF.
                if self.receiveComplete,
                   self.audioFileStream?.parsingComplete == true,
                   audioBuffersQueue.isEmpty
                {
                    // True EOF → finish as before.
                    onTimeChanged(audioBuffersQueue.duration)
                    audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                    onRateChanged(0.0)
                    onComplete()
                    invalidate()
                } else {
                    // Not EOF → we're temporarily stalled (rebuffering).
                    if !isBuffering {
                        isBuffering = true
                        onBuffering()
                    } else {
                        // Already buffering - try force exit if conditions are met
                        forceExitBufferingIfPossible()
                    }
                    onTimeChanged(time)
                }
            } else {
                if isBuffering { 
                    isBuffering = false
                    // Force a media data request to ensure playback resumes
                    if let audioRenderer = self.audioRenderer {
                        audioRenderer.requestMediaDataWhenReady(on: queue) {
                            // This will trigger the existing media request logic
                        }
                    }
                }
                onTimeChanged(time)
            }
        }
    }

    private func updateCurrentBufferIfNeeded(at time: CMTime) {
        guard let audioBuffersQueue,
              let buffer = audioBuffersQueue.buffer(at: time),
              buffer.presentationTimeStamp != currentSampleBufferTime else { return }
        onSampleBufferChanged(buffer)
        currentSampleBufferTime = buffer.presentationTimeStamp
    }

    private func cancelTimeObservation() {
        audioRendererTimeCancellable?.cancel()
        audioRendererTimeCancellable = nil
    }

    private func observeError(_ audioRenderer: AVSampleBufferAudioRenderer) {
        cancelErrorObservation()
        audioRendererErrorCancellable = audioRenderer.publisher(for: \.error).sink { [weak self] error in
            guard let self else { return }
            onError(error.flatMap(AudioPlayerError.init))
        }
    }

    private func cancelErrorObservation() {
        audioRendererErrorCancellable?.cancel()
        audioRendererErrorCancellable = nil
    }
}
