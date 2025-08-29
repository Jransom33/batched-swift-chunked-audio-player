@preconcurrency import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
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
    
    // MARK: - Buffer Thresholds
    /// Consistent buffer threshold for both initial playback and buffering recovery
    /// This prevents infinite buffering loops where recovery threshold > initial threshold
    /// 
    /// Note: 1.5s was insufficient to prevent choppy word-by-word playback, increased to 2.0s
    /// to ensure smooth continuous playback without buffering between words
    private static let bufferThreshold: Double = 2.0
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
            // Only feed buffers to renderer if synchronizer is actually playing or we have sufficient buffer
            let shouldFeedRenderer = audioSynchronizer?.rate != 0 || audioBuffersQueue.duration.seconds >= Self.bufferThreshold
            
            if shouldFeedRenderer {
                while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                    audioRenderer.enqueue(buffer)
                    audioBuffersQueue.removeFirst()
                    onDurationChanged(audioBuffersQueue.duration)
                    enqueuedAny = true
                    startPlaybackIfNeeded(didStart: &didStart)
                }
            } else {
                throttledBufferLog("⏳ HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", Self.bufferThreshold))s)", throttleKey: "holding_buffers", throttleInterval: 2.0)
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
                    
                    // NOTE: Disabled zombie state detection as it was causing crashes
                    // The regular buffering logic with minimum thresholds should handle recovery
                    // if !validateSynchronizerState() {
                    //     bufferLog("🚨 ZOMBIE STATE ON EXIT - Emergency restart required")
                    //     restartAudioPipeline()
                    // }
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
            // Only feed buffers to renderer if synchronizer is actually playing or we have sufficient buffer
            let shouldFeedRenderer = audioSynchronizer.rate != 0 || audioBuffersQueue.duration.seconds >= Self.bufferThreshold
            
            if shouldFeedRenderer {
                while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                    audioRenderer.enqueue(buffer)
                    audioBuffersQueue.removeFirst()
                    onDurationChanged(audioBuffersQueue.duration)
                    enqueuedAny = true
                }
            } else {
                throttledBufferLog("⏳ RESTART HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", Self.bufferThreshold))s)", throttleKey: "restart_holding_buffers", throttleInterval: 2.0)
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
              let audioBuffersQueue,
              audioSynchronizer.rate == 0,
              !didStart else { return }
        
        let dataComplete = receiveComplete && audioFileStream.parsingComplete
        let hasSufficientSystemData = audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
        let initialBufferThreshold: Double = Self.bufferThreshold // Require consistent buffer before starting
        let hasEnoughBuffer = audioBuffersQueue.duration.seconds >= initialBufferThreshold
        
        // Only start if we have enough buffer OR the stream is complete with any data
        let shouldStart = (hasSufficientSystemData && hasEnoughBuffer) || (dataComplete && !audioBuffersQueue.isEmpty)
        
        if shouldStart {
            bufferLog("🎯 STARTING PLAYBACK - Conditions met (sufficient: \(hasSufficientSystemData), buffer: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, dataComplete: \(dataComplete))")
            // CRITICAL FIX: Start at 1.0x rate first to establish stable timebase, then set desired rate
            audioSynchronizer.setRate(1.0, time: .zero)
            // Allow timebase to stabilize before setting desired rate
            if desiredRate != 1.0 {
                audioSynchronizer.setRate(desiredRate, time: audioSynchronizer.currentTime())
            }
            didStart = true
            isBuffering = false
            onPlaying()
        } else {
            throttledBufferLog("⏸️ PLAYBACK NOT READY - Waiting for \(String(format: "%.1f", initialBufferThreshold))s buffer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, sufficient: \(hasSufficientSystemData), dataComplete: \(dataComplete))", throttleKey: "not_ready", throttleInterval: 2.0)
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
        let bufferAhead = queueDuration - currentTime
        
        // MINIMUM BUFFER THRESHOLD: Use same threshold as initial playback for consistency
        // This prevents infinite buffering loops where recovery threshold > initial threshold
        let minimumBufferThreshold: Double = Self.bufferThreshold
        
        bufferLog("🔍 FORCE EXIT CHECK - hasBuffers: \(hasBuffers), hasSufficientData: \(hasSufficientData), queueDuration: \(String(format: "%.2f", queueDuration))s, currentTime: \(String(format: "%.2f", currentTime))s, bufferAhead: \(String(format: "%.2f", bufferAhead))s")
        
        // Check if we have enough buffered content ahead of current playback position
        let hasMinimumBuffer = bufferAhead >= minimumBufferThreshold
        
        // Only exit buffering if we have sufficient buffer OR the stream is complete
        let isStreamComplete = receiveComplete && (audioFileStream?.parsingComplete == true)
        
        // Additional fallback: if we have reasonable buffer and synchronizer hasn't started yet (currentTime ~= 0)
        // treat the full queue duration as available buffer
        let isInitialState = currentTime < 0.1 // Player hasn't really started yet
        let hasReasonableInitialBuffer = isInitialState && queueDuration >= minimumBufferThreshold
        
        let shouldForceExit = (hasBuffers && hasMinimumBuffer) || 
                             (isStreamComplete && hasBuffers) || 
                             (hasSufficientData && hasMinimumBuffer) ||
                             (hasReasonableInitialBuffer && hasBuffers)
        
        if shouldForceExit {
            bufferLog("🚑 FORCING EXIT FROM BUFFERING - Recovery conditions met (minBuffer: \(hasMinimumBuffer), streamComplete: \(isStreamComplete), sufficient: \(hasSufficientData), initialBuffer: \(hasReasonableInitialBuffer))")
            isBuffering = false
            
            // Force the synchronizer to resume if it's stopped
            if audioSynchronizer.rate == 0 {
                bufferLog("🎬 FORCE RESUME - Restarting synchronizer at rate \(desiredRate)")
                // CRITICAL FIX: Start at 1.0x rate first to establish stable timebase, then set desired rate
                audioSynchronizer.setRate(1.0, time: audioSynchronizer.currentTime())
                if desiredRate != 1.0 {
                    audioSynchronizer.setRate(desiredRate, time: audioSynchronizer.currentTime())
                }
                onPlaying()
            }
            
            // Restart media data requests immediately
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                // This will re-trigger the normal media request logic
                self.handleMediaDataRequest(renderer: audioRenderer, synchronizer: audioSynchronizer)
            }
        } else {
            bufferLog("⏳ FORCE EXIT SKIPPED - Insufficient buffer (need \(String(format: "%.1f", minimumBufferThreshold))s, have \(String(format: "%.2f", bufferAhead))s) | buffers: \(hasBuffers), sufficient: \(hasSufficientData), streamComplete: \(isStreamComplete), initialBuffer: \(hasReasonableInitialBuffer))")
        }
    }
    
    private func handleMediaDataRequest(renderer: AVSampleBufferAudioRenderer, synchronizer: AVSampleBufferRenderSynchronizer) {
        guard let audioBuffersQueue = self.audioBuffersQueue else { 
            bufferLog("⚠️ HANDLE MEDIA REQUEST FAILED - No audioBuffersQueue")
            return 
        }
        
        throttledBufferLog("🔄 HANDLING MEDIA DATA REQUEST - Queue size: \(audioBuffersQueue.isEmpty ? 0 : 1), isReady: \(renderer.isReadyForMoreMediaData)", throttleKey: "media_request", throttleInterval: 2.0)
        
        var enqueuedAny = false
        // Only feed buffers to renderer if synchronizer is actually playing or we have sufficient buffer
        let shouldFeedRenderer = audioSynchronizer?.rate != 0 || audioBuffersQueue.duration.seconds >= Self.bufferThreshold
        
        if shouldFeedRenderer {
            while let buffer = audioBuffersQueue.peek(), renderer.isReadyForMoreMediaData {
                renderer.enqueue(buffer)
                audioBuffersQueue.removeFirst()
                onDurationChanged(audioBuffersQueue.duration)
                enqueuedAny = true
            }
        } else {
            throttledBufferLog("⏳ HANDLE HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", Self.bufferThreshold))s)", throttleKey: "handle_holding_buffers", throttleInterval: 2.0)
        }
        
        // If we successfully enqueued data and synchronizer is stopped, start it
        if enqueuedAny && synchronizer.rate == 0 {
            bufferLog("🎬 STARTING PLAYBACK - Enqueued data and synchronizer was stopped")
            // CRITICAL FIX: Start at 1.0x rate first to establish stable timebase, then set desired rate
            synchronizer.setRate(1.0, time: synchronizer.currentTime())
            if desiredRate != 1.0 {
                synchronizer.setRate(desiredRate, time: synchronizer.currentTime())
            }
            isBuffering = false
            onPlaying()
        } else if enqueuedAny {
            bufferLog("📤 ENQUEUED DATA - Synchronizer running at rate: \(synchronizer.rate)")
            // NOTE: Disabled zombie state check to prevent crashes
            // The buffering logic with minimum thresholds should handle playback issues
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
        
        // Complete teardown
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
        
        // Remove renderer first to avoid "Cannot add renderer more than once" crash
        synchronizer.removeRenderer(renderer, at: .zero) { [weak self] _ in
            guard let self else { return }
            
            // Force a brief delay to let the system settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                
                // Rebuild the synchronizer connection
                synchronizer.addRenderer(renderer)
                // CRITICAL FIX: Start at 1.0x rate first to establish stable timebase, then set desired rate
                synchronizer.setRate(1.0, time: .zero)
                if desiredRate != 1.0 {
                    synchronizer.setRate(desiredRate, time: synchronizer.currentTime())
                }
                
                bufferLog("✅ PIPELINE RESTART COMPLETE - Synchronizer reconnected")
                self.isBuffering = false
                self.onPlaying()
            }
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
               let audioSynchronizer
            {
                let currentTime = time.seconds
                let queueDuration = audioBuffersQueue.duration.seconds
                let bufferAhead = queueDuration - currentTime
                let minimumBufferThreshold: Double = 0.5 // Start buffering when less than 500ms ahead
                
                // Check if we're running low on buffer OR completely caught up
                let isRunningLowOnBuffer = bufferAhead <= minimumBufferThreshold
                let isCaughtUpCompletely = time + epsilon >= audioBuffersQueue.duration
                
                if isCaughtUpCompletely {
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
                            bufferLog("🌀 ENTERED BUFFERING - Player caught up to buffered content (time: \(String(format: "%.2f", currentTime))s, buffered: \(String(format: "%.2f", queueDuration))s)")
                            
                            // Pause the synchronizer to stop time advancement during buffering
                            // CRITICAL FIX: Reset timebase to zero to prevent it from racing ahead
                            audioSynchronizer.setRate(0.0, time: .zero)
                            bufferLog("⏸️ PAUSED SYNCHRONIZER - Reset timebase to zero during buffering")
                            
                            onBuffering()
                            
                            // Immediately try to recover - sometimes we have buffer but it's not being detected
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                self?.forceExitBufferingIfPossible()
                            }
                        } else {
                            // Already buffering - try force exit if conditions are met
                            throttledBufferLog("🔄 STILL BUFFERING - Attempting force exit (time: \(String(format: "%.2f", currentTime))s, queue: \(String(format: "%.2f", queueDuration))s)", throttleKey: "still_buffering", throttleInterval: 3.0)
                            forceExitBufferingIfPossible()
                        }
                        // DON'T update time during buffering - this prevents the UI from showing false progress
                        // onTimeChanged(time) is intentionally commented out
                    }
                } else if isRunningLowOnBuffer && !isBuffering {
                    // Preemptive buffering: Start buffering before we completely run out
                    let isStreamComplete = receiveComplete && (audioFileStream?.parsingComplete == true)
                    if !isStreamComplete {
                        isBuffering = true
                        bufferLog("⚠️ PREEMPTIVE BUFFERING - Running low on buffer (bufferAhead: \(String(format: "%.2f", bufferAhead))s, threshold: \(String(format: "%.1f", minimumBufferThreshold))s)")
                        
                        // Pause the synchronizer to stop time advancement during buffering
                        // CRITICAL FIX: Reset timebase to zero to prevent it from racing ahead
                        audioSynchronizer.setRate(0.0, time: .zero)
                        bufferLog("⏸️ PAUSED SYNCHRONIZER - Reset timebase to zero preemptively")
                        
                        onBuffering()
                        
                        // Try to recover after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.forceExitBufferingIfPossible()
                        }
                    }
                }
            } else {
                if isBuffering { 
                    isBuffering = false
                    bufferLog("✅ EXITED BUFFERING - Player has available buffer ahead (time: \(String(format: "%.2f", time.seconds))s)")
                    
                    // Resume the synchronizer at the desired rate
                    if let audioSynchronizer = audioSynchronizer {
                        // CRITICAL FIX: Start at 1.0x rate from zero to establish stable timebase, then set desired rate
                        audioSynchronizer.setRate(1.0, time: .zero)
                        if desiredRate != 1.0 {
                            audioSynchronizer.setRate(desiredRate, time: audioSynchronizer.currentTime())
                        }
                        bufferLog("▶️ RESUMED SYNCHRONIZER - Restarting playback from zero at rate \(desiredRate)")
                    }
                    
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
        
        // CRITICAL FIX: Initialize synchronizer timebase immediately after adding renderer
        // This prevents the "TIME STUCK AT ZERO" zombie state where synchronizer rate > 0 
        // but timebase never starts advancing.
        
        // Step 1: Ensure the synchronizer starts its master clock
        synchronizer.rate = 0.0  // Reset to ensure clean state
        
        // Step 2: Use setRate with explicit time to force timebase initialization
        synchronizer.setRate(1.0, time: CMTime.zero)
        
        // Step 3: Immediately verify timebase is running by checking currentTime after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let verificationTime = synchronizer.currentTime()
            bufferLog("🔧 TIMEBASE VERIFICATION - currentTime after init: \(verificationTime.seconds)s")
            
            // If still stuck at zero, try alternative initialization
            if verificationTime.seconds == 0.0 {
                bufferLog("⚠️ TIMEBASE STUCK - Attempting alternative initialization")
                // Force start the synchronizer's master clock
                synchronizer.rate = 1.0
                synchronizer.setRate(1.0, time: CMTime.zero)
            }
        }
        
        bufferLog("🔧 SYNCHRONIZER TIMEBASE INITIALIZED - setRate(1.0, time: CMTime.zero)")
        
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
