import AVFoundation
import AudioToolbox
import Combine
import Foundation

// MARK: - Buffering Logging Helper
private func bufferLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date())
    print("👻👻👻 [\(timestamp)] [BUFFER] \(message)")
}

// MARK: - Throttled Logging Helper
private actor LogThrottler {
    private var lastLogs: [String: Date] = [:]
    
    func shouldLog(key: String, interval: TimeInterval) -> Bool {
        let now = Date()
        if let lastLog = lastLogs[key], now.timeIntervalSince(lastLog) < interval {
            return false
        }
        lastLogs[key] = now
        return true
    }
}

private let logThrottler = LogThrottler()

private func throttledBufferLog(_ message: String, throttleKey: String, throttleInterval: TimeInterval = 1.0) {
    Task {
        if await logThrottler.shouldLog(key: throttleKey, interval: throttleInterval) {
            bufferLog(message)
        }
    }
}

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
        receiveComplete = false
        audioFileStream = AudioFileStream(type: type, queue: queue) { [weak self] error in
            self?.onError(error)
        } receiveASBD: { [weak self] asbd in
            self?.handleAudioStreamDescription(asbd: asbd)
        } receivePackets: { [weak self] numberOfBytes, bytes, numberOfPackets, packets in
            self?.handleAudioStreamPackets(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
        }
        audioFileStream?.open()
        bufferLog("🎵 AUDIO STREAM PREPARED - Ready to receive audio data")
    }
    
    func parseData(_ data: Data) {
        guard let audioFileStream = audioFileStream else {
            bufferLog("❌ PARSE DATA FAILED - AudioFileStream not prepared")
            return
        }
        bufferLog("🔄 PARSING \(data.count) bytes of audio data")
        audioFileStream.parseData(data)
    }
    
    func markReceiveComplete() {
        receiveComplete = true
        bufferLog("🏁 MARKED RECEIVE COMPLETE - No more audio data expected")
        
        // Force exit buffering if we're waiting and this is the end
        if isBuffering {
            bufferLog("🚑 STREAM COMPLETE DURING BUFFERING - Attempting final recovery")
            forceExitBufferingIfPossible()
        }
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
                if !isBuffering { 
                    isBuffering = true
                    bufferLog("🔴 MEDIA REQUEST DETECTED BUFFERING - No buffers available to enqueue")
                    onBuffering() 
                }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    bufferLog("💚 MEDIA REQUEST EXITED BUFFERING - Buffers available, enqueuedAny: \(enqueuedAny)")
                    
                    // Check for zombie state when exiting buffering
                    if !validateSynchronizerState() {
                        bufferLog("🚨 ZOMBIE STATE ON EXIT - Emergency restart required")
                        restartAudioPipeline()
                    }
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
                if !isBuffering { 
                    isBuffering = true
                    bufferLog("🔴 RESTART REQUEST DETECTED BUFFERING - No buffers available to enqueue")
                    onBuffering() 
                }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    bufferLog("💚 RESTART REQUEST EXITED BUFFERING - Buffers available, enqueuedAny: \(enqueuedAny)")
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
        
        if shouldStart {
            bufferLog("🎯 STARTING PLAYBACK - Sufficient media data available (dataComplete: \(dataComplete))")
            audioSynchronizer.setRate(desiredRate, time: .zero)
            didStart = true
            isBuffering = false
            onPlaying()
        } else {
            throttledBufferLog("⏸️ PLAYBACK NOT READY - Insufficient media data (dataComplete: \(dataComplete), hasSufficient: \(audioRenderer.hasSufficientMediaDataForReliablePlaybackStart))", throttleKey: "not_ready", throttleInterval: 2.0)
        }
    }
    
    private func forceExitBufferingIfPossible() {
        guard isBuffering,
              let audioRenderer = self.audioRenderer,
              let audioSynchronizer = self.audioSynchronizer,
              let audioBuffersQueue = self.audioBuffersQueue else { 
            if isBuffering {
                bufferLog("⚠️ FORCE EXIT FAILED - Missing components")
            }
            return 
        }
        
        // Check if we have any buffers available or sufficient media data
        let hasBuffers = !audioBuffersQueue.isEmpty
        let hasSufficientData = audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
        let queueDuration = audioBuffersQueue.duration.seconds
        let currentTime = audioSynchronizer.currentTime().seconds
        
        bufferLog("🔍 FORCE EXIT CHECK - hasBuffers: \(hasBuffers), hasSufficientData: \(hasSufficientData), queueDuration: \(String(format: "%.2f", queueDuration))s, currentTime: \(String(format: "%.2f", currentTime))s")
        
        // More aggressive exit conditions - even tiny amounts of buffered audio should allow resumption
        let hasAnyBufferedContent = queueDuration > currentTime + 0.1 // At least 100ms ahead
        let shouldForceExit = hasBuffers || hasSufficientData || hasAnyBufferedContent
        
        if shouldForceExit {
            bufferLog("🚑 FORCING EXIT FROM BUFFERING - Recovery conditions met")
            isBuffering = false
            
            // Force the synchronizer to resume if it's stopped
            if audioSynchronizer.rate == 0 {
                bufferLog("🎬 FORCE RESUME - Restarting synchronizer at rate \(desiredRate)")
                audioSynchronizer.setRate(desiredRate, time: audioSynchronizer.currentTime())
                onPlaying()
            }
            
            // Restart media data requests immediately
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                // This will re-trigger the normal media request logic
                self.handleMediaDataRequest(renderer: audioRenderer, synchronizer: audioSynchronizer)
            }
        } else {
            bufferLog("⏳ FORCE EXIT SKIPPED - No recovery conditions met (buffers: \(hasBuffers), sufficient: \(hasSufficientData), hasContent: \(hasAnyBufferedContent))")
        }
    }
    
    private func handleMediaDataRequest(renderer: AVSampleBufferAudioRenderer, synchronizer: AVSampleBufferRenderSynchronizer) {
        guard let audioBuffersQueue = self.audioBuffersQueue else { 
            bufferLog("⚠️ HANDLE MEDIA REQUEST FAILED - No audioBuffersQueue")
            return 
        }
        
        throttledBufferLog("🔄 HANDLING MEDIA DATA REQUEST - Queue size: \(audioBuffersQueue.isEmpty ? 0 : 1), isReady: \(renderer.isReadyForMoreMediaData)", throttleKey: "media_request", throttleInterval: 2.0)
        
        var enqueuedAny = false
        while let buffer = audioBuffersQueue.peek(), renderer.isReadyForMoreMediaData {
            renderer.enqueue(buffer)
            audioBuffersQueue.removeFirst()
            onDurationChanged(audioBuffersQueue.duration)
            enqueuedAny = true
        }
        
        // If we successfully enqueued data and synchronizer is stopped, start it
        if enqueuedAny && synchronizer.rate == 0 {
            bufferLog("🎬 STARTING PLAYBACK - Enqueued data and synchronizer was stopped")
            synchronizer.setRate(desiredRate, time: synchronizer.currentTime())
            isBuffering = false
            onPlaying()
        } else if enqueuedAny {
            bufferLog("📤 ENQUEUED DATA - But synchronizer already running (rate: \(synchronizer.rate))")
            // Check if synchronizer is in zombie state
            if !validateSynchronizerState() {
                bufferLog("🚨 SYNCHRONIZER ZOMBIE STATE DETECTED - Forcing restart")
                restartAudioPipeline()
            }
        } else {
            throttledBufferLog("❌ NO DATA ENQUEUED - No buffers available or renderer not ready", throttleKey: "no_data", throttleInterval: 3.0)
        }
    }
    
    private func validateSynchronizerState() -> Bool {
        guard let synchronizer = audioSynchronizer,
              let renderer = audioRenderer else { return false }
        
        // Check if synchronizer is actually playing vs just "running"
        let isActuallyPlaying = synchronizer.rate > 0 && 
                               renderer.isReadyForMoreMediaData
        
        bufferLog("🔍 SYNCHRONIZER STATE - Rate: \(synchronizer.rate), RendererReady: \(renderer.isReadyForMoreMediaData), ActuallyPlaying: \(isActuallyPlaying)")
        
        return isActuallyPlaying
    }
    
    private func restartAudioPipeline() {
        bufferLog("🚨 EMERGENCY PIPELINE RESTART - Rebuilding synchronizer connection")
        
        guard let renderer = audioRenderer,
              let synchronizer = audioSynchronizer else {
            bufferLog("❌ RESTART FAILED - Missing renderer or synchronizer")
            return
        }
        
        // Complete teardown and rebuild
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
        
        // Force a brief delay to let the system settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            
            // Rebuild the synchronizer connection
            synchronizer.addRenderer(renderer)
            synchronizer.setRate(desiredRate, time: .zero)
            
            bufferLog("✅ PIPELINE RESTART COMPLETE - Synchronizer reconnected")
            self.isBuffering = false
            self.onPlaying()
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
                        bufferLog("🌀 ENTERED BUFFERING - Player caught up to buffered content (time: \(String(format: "%.2f", time.seconds))s, buffered: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s)")
                        onBuffering()
                        
                        // Immediately try to recover - sometimes we have buffer but it's not being detected
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            self?.forceExitBufferingIfPossible()
                        }
                    } else {
                        // Already buffering - try force exit if conditions are met
                        throttledBufferLog("🔄 STILL BUFFERING - Attempting force exit (time: \(String(format: "%.2f", time.seconds))s, queue: \(audioBuffersQueue.duration.seconds)s)", throttleKey: "still_buffering", throttleInterval: 3.0)
                        forceExitBufferingIfPossible()
                    }
                    onTimeChanged(time)
                }
            } else {
                if isBuffering { 
                    isBuffering = false
                    bufferLog("✅ EXITED BUFFERING - Player has available buffer ahead (time: \(String(format: "%.2f", time.seconds))s)")
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
    
    // MARK: - AudioFileStream Callbacks
    
    private func handleAudioStreamDescription(asbd: AudioStreamBasicDescription) {
        bufferLog("🎧 RECEIVED AUDIO DESCRIPTION - Format: \(asbd.mFormatID), Channels: \(asbd.mChannelsPerFrame), SampleRate: \(asbd.mSampleRate)")
        
        // Create and setup audio renderer and synchronizer
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = initialVolume
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        audioBuffersQueue = AudioBuffersQueue(audioDescription: asbd)
        
        bufferLog("🎬 AUDIO RENDERER CREATED - Starting media data requests")
        observeRenderer(renderer, synchronizer: synchronizer)
        startRequestingMediaData(renderer)
    }
    
    private func handleAudioStreamPackets(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        bufferLog("🎧 RECEIVED \(numberOfPackets) PACKETS - \(numberOfBytes) bytes")
        
        guard let audioBuffersQueue = self.audioBuffersQueue else {
            bufferLog("❌ PACKETS DROPPED - No AudioBuffersQueue")
            return
        }
        
        do {
            try audioBuffersQueue.enqueue(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
            
            bufferLog("✅ ENQUEUED PACKETS - Queue duration: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, isEmpty: \(audioBuffersQueue.isEmpty)")
            onDurationChanged(audioBuffersQueue.duration)
            
            // Force exit buffering if we have new data
            if isBuffering {
                bufferLog("🚑 NEW BUFFER ARRIVED DURING BUFFERING - Attempting force exit")
                forceExitBufferingIfPossible()
            }
            
        } catch {
            bufferLog("❌ FAILED TO ENQUEUE PACKETS - Error: \(error)")
            onError(AudioPlayerError.other(error))
        }
    }

}
