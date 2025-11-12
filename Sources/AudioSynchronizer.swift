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

private struct ChunkBudget {
    let chunkIndex: Int
    var leadingFramesRemaining: Int
    var playableFramesRemaining: Int?
    let totalPlayableFrames: Int?
    let trailingPaddingFrames: Int
}

private func throttledBufferLog(_ message: String, throttleKey: String, throttleInterval: TimeInterval = 1.0) {
    Task {
        if await logThrottler.shouldLog(key: throttleKey, interval: throttleInterval) {
            bufferLog(message)
        }
    }
}

final class AudioSynchronizer: Sendable {
    
    // MARK: - Buffer Thresholds
    /// Dynamic buffer threshold that adapts to playback rate
    /// Conservative thresholds to prevent constant buffering on small fluctuations
    /// Uses larger safety margins at higher rates
    private func bufferThreshold(for rate: Float) -> Double {
        // Conservative but reasonable thresholds that scale with playback rate
        // Balance between stability and responsiveness for TTS streaming
        if rate <= 1.0 {
            return 1.5  // 1x speed: 1.5s threshold
        } else if rate <= 1.5 {
            return 2.0  // 1.5x speed: 2.0s threshold  
        } else {
            return 2.5  // 2x+ speed: 2.5s threshold - stable but responsive
        }
    }
    
    /// Legacy constant threshold for compatibility
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

    private nonisolated(unsafe) var chunkBudgets: [ChunkBudget] = []

    nonisolated(unsafe) var desiredRate: Float = 1.0 {
        didSet {
            bufferLog("📊 DIAG RATE CHANGE: desiredRate \(oldValue) → \(desiredRate)")
            print("🟣 [RATE_CHANGE] Desired rate changed: \(oldValue) → \(desiredRate)")
            if desiredRate == 0.0 {
                pause()
            } else {
                resume(at: desiredRate)
            }
        }
    }

    // MARK: - Diagnostics (lightweight)
    private nonisolated(unsafe) var diagEnabled = false
    private nonisolated(unsafe) var diagLastTick: Date = .distantPast
    private nonisolated(unsafe) var diagBytesReceivedThisTick: Int = 0
    
    // MARK: - Synchronizer Rate Tracking
    private func setSynchronizerRate(_ rate: Float, time: CMTime, context: String = "") {
        let timeSecs = time.seconds
        let currentTimeSecs = audioSynchronizer?.currentTime().seconds ?? 0.0
        print("🟣 [SYNC_RATE] Setting rate: \(rate)x at time: \(String(format: "%.3f", timeSecs))s | Current: \(String(format: "%.3f", currentTimeSecs))s | Context: \(context)")
        
        // DIAGNOSTIC: Track unexpected timebase jumps
        if currentTimeSecs > 0.5 && rate > 0.0 && context != "resume" {
            print("🚨 [TIMEBASE_JUMP] Unexpected timebase advancement! Current: \(String(format: "%.3f", currentTimeSecs))s before setting rate \(rate)x | Context: \(context)")
        }
        
        audioSynchronizer?.setRate(rate, time: time)
        
        // DIAGNOSTIC: Check if timebase jumped after setRate
        let newCurrentTime = audioSynchronizer?.currentTime().seconds ?? 0.0
        if abs(newCurrentTime - timeSecs) > 0.1 {
            print("🚨 [SETRATE_JUMP] Timebase jumped! Expected: \(String(format: "%.3f", timeSecs))s, Actual: \(String(format: "%.3f", newCurrentTime))s | Rate: \(rate)x | Context: \(context)")
        }
    }
    private nonisolated(unsafe) var diagAudioSecondsEnqueuedThisTick: Double = 0
    private nonisolated(unsafe) var diagBuffersEnqueuedThisTick: Int = 0
    private nonisolated(unsafe) var diagEnqueueLoopsThisTick: Int = 0
    private nonisolated(unsafe) var diagLastQueueDurationSeconds: Double = 0

    // MARK: - Stream metadata tracking
    private nonisolated(unsafe) var audioStreamDescription: AudioStreamBasicDescription?
    private nonisolated(unsafe) var packetTableInfo: AudioFilePacketTableInfo?
    private nonisolated(unsafe) var totalPacketFramesReceived: Int64 = 0
    private nonisolated(unsafe) var totalPacketBatches: Int64 = 0
    private nonisolated(unsafe) var frameComputationFallbackLogged = false
    private nonisolated(unsafe) var missingPacketDescriptionsLogged = false
    private nonisolated(unsafe) var packetInfoStatusCache: [AudioFilePropertyID: OSStatus] = [:]
    private nonisolated(unsafe) var paddingSummaryLogged = false

    // MARK: - Event-driven logging state
    private nonisolated(unsafe) var lastRendererReady: Bool? = nil
    private nonisolated(unsafe) var lastBufferAheadBelowThreshold: Bool? = nil
    private nonisolated(unsafe) var lastLoggedRate: Float? = nil

    private func emitDiagnosticsIfNeeded(context: String) {
        guard diagEnabled else { return }
        let now = Date()
        if diagLastTick == .distantPast { diagLastTick = now }
        let dt = now.timeIntervalSince(diagLastTick)
        guard dt >= 1.0 else { return }
        let bytesPerSec = Double(diagBytesReceivedThisTick) / dt
        let audioSecPerSec = diagAudioSecondsEnqueuedThisTick / dt
        throttledBufferLog(
            String(
                format: "📊 DIAG [%@] ingest: %.1f KB/s, audio %+0.2f s/s, enqLoops: %d, buffers: %d",
                context,
                bytesPerSec / 1024.0,
                audioSecPerSec,
                diagEnqueueLoopsThisTick,
                diagBuffersEnqueuedThisTick
            ),
            throttleKey: "diag_\(context)",
            throttleInterval: 1.0
        )
        // reset tick
        diagLastTick = now
        diagBytesReceivedThisTick = 0
        diagAudioSecondsEnqueuedThisTick = 0
        diagBuffersEnqueuedThisTick = 0
        diagEnqueueLoopsThisTick = 0
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

    func beginChunk(
        chunkIndex: Int,
        primingFrames: Int,
        playableFrames: Int?,
        trailingPaddingFrames: Int
    ) {
        let leading = max(primingFrames, 0)
        let playable = playableFrames.flatMap { $0 >= 0 ? $0 : nil }
        queue.async { [weak self] in
            guard let self else { return }
            self.chunkBudgets.append(
                ChunkBudget(
                    chunkIndex: chunkIndex,
                    leadingFramesRemaining: leading,
                    playableFramesRemaining: playable,
                    totalPlayableFrames: playable,
                    trailingPaddingFrames: max(trailingPaddingFrames, 0)
                )
            )
            bufferLog("✂️ [CHUNK_TRIM] Scheduled chunk \(chunkIndex) - leading=\(leading) frames, playable=\(playable ?? -1) frames, trailing=\(trailingPaddingFrames) frames")
        }
    }

    func prepare(type: AudioFileTypeID? = nil) {
        invalidate()
        receiveComplete = false
        chunkBudgets.removeAll()
        audioStreamDescription = nil
        packetTableInfo = nil
        totalPacketFramesReceived = 0
        totalPacketBatches = 0
        frameComputationFallbackLogged = false
        missingPacketDescriptionsLogged = false
        packetInfoStatusCache = [:]
        paddingSummaryLogged = false
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
        } receivePacketTableInfo: { [weak self] info, propertyID, status in
            self?.handlePacketTableInfo(info, propertyID: propertyID, status: status)
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
        // Use time-based rate change to ensure timebase consistency
        setSynchronizerRate(newRate, time: audioSynchronizer.currentTime(), context: "resume")
        if oldRate == 0.0 && newRate > 0.0 {
            bufferLog("🎬 [STATE] Calling onPlaying() - UI should show playing state")
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
        if diagEnabled { 
            diagBytesReceivedThisTick += data.count 
            // Immediate diagnostic for data ingestion
            bufferLog("📊 DIAG INGEST: +\(data.count) bytes (total this tick: \(diagBytesReceivedThisTick))")
        }
        audioFileStream?.parseData(data)
    }

    func finish() {
        audioFileStream?.finishDataParsing()
        receiveComplete = true
        queue.async { [weak self] in
            self?.logPaddingSummaryIfPossible(reason: "finish")
        }
    }

    func invalidate(_ completion: @escaping @Sendable () -> Void = {}) {
        removeBuffers()
        closeFileStream()
        cancelObservation()
        receiveComplete = false
        chunkBudgets.removeAll()
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
            let currentRate = audioSynchronizer?.rate ?? 1.0
            let threshold = bufferThreshold(for: currentRate)
            let shouldFeedRenderer = audioSynchronizer?.rate != 0 || audioBuffersQueue.duration.seconds >= threshold
            
            if shouldFeedRenderer {
                while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                    let bufferStart = buffer.presentationTimeStamp.seconds
                    let bufferEnd = bufferStart + buffer.duration.seconds
                    let queueDurationBefore = audioBuffersQueue.duration.seconds
                    
                    audioRenderer.enqueue(buffer)
                    audioBuffersQueue.removeFirst()
                    
                    let queueDurationAfter = audioBuffersQueue.duration.seconds
                    // print("🎯 [FEED_TO_RENDERER] Fed buffer [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Queue duration: \(String(format: "%.3f", queueDurationBefore))s → \(String(format: "%.3f", queueDurationAfter))s")
                    
                    onDurationChanged(audioBuffersQueue.duration)
                    enqueuedAny = true
                    if diagEnabled {
                        diagBuffersEnqueuedThisTick += 1
                        diagAudioSecondsEnqueuedThisTick += buffer.duration.seconds
                    }
                    startPlaybackIfNeeded(didStart: &didStart)
                }
            } else {
                throttledBufferLog("⏳ HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", threshold))s)", throttleKey: "holding_buffers", throttleInterval: 2.0)
            }
            emitDiagnosticsIfNeeded(context: "feed")
            startPlaybackIfNeeded(didStart: &didStart)

            if !enqueuedAny,
               audioRenderer.isReadyForMoreMediaData,
               !(receiveComplete && (audioFileStream?.parsingComplete == true))
            {
                if !isBuffering { 
                    isBuffering = true
                    bufferLog("🔴 MEDIA REQUEST DETECTED BUFFERING - No buffers available to enqueue")

                    // CRITICAL FIX: Pause the synchronizer to prevent time advancement during buffering
                    if let audioSynchronizer = audioSynchronizer {
                        audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                        bufferLog("⏸️ PAUSED SYNCHRONIZER - Stopped time progression during media request buffering")
                    }

                    bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                                            bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                        onBuffering() 
                }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    bufferLog("💚 MEDIA REQUEST EXITED BUFFERING - Buffers available, enqueuedAny: \(enqueuedAny)")
                    // FIX: Always resume rate if paused
                    if let synchronizer = audioSynchronizer, synchronizer.rate == 0 {
                        bufferLog("🎬 EXIT RESUME - Restarting synchronizer at rate \(desiredRate)")
                        setSynchronizerRate(desiredRate, time: synchronizer.currentTime(), context: "exitBuffering")
                        bufferLog("✅ EXIT RESUME - Applied desired rate \(desiredRate), actual rate: \(synchronizer.rate)")
                        onPlaying()
                    }
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
                    // Only feed buffers to renderer if synchronizer is actually playing or we have sufficient buffer
        let currentRate = audioSynchronizer.rate
        let threshold = bufferThreshold(for: currentRate)
        let shouldFeedRenderer = audioSynchronizer.rate != 0 || audioBuffersQueue.duration.seconds >= threshold
            
            if shouldFeedRenderer {
                var buffersFeToRenderer = 0
                var totalDurationFed: Double = 0
                
                while let buffer = audioBuffersQueue.peek(), audioRenderer.isReadyForMoreMediaData {
                    let bufferDuration = buffer.duration.seconds
                    let bufferStart = buffer.presentationTimeStamp.seconds
                    let bufferEnd = bufferStart + bufferDuration
                    let rendererReadyState = audioRenderer.isReadyForMoreMediaData
                    
                // print("🟧 [RESTART_FEED] Feeding buffer: \(String(format: "%.3f", bufferDuration))s [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Renderer ready: \(rendererReadyState)")
                    
                    audioRenderer.enqueue(buffer)
                    audioBuffersQueue.removeFirst()
                    onDurationChanged(audioBuffersQueue.duration)
                    enqueuedAny = true
                    buffersFeToRenderer += 1
                    totalDurationFed += bufferDuration
                    
                    if diagEnabled {
                        diagBuffersEnqueuedThisTick += 1
                        diagAudioSecondsEnqueuedThisTick += buffer.duration.seconds
                    }
                }
                
                // if buffersFeToRenderer > 0 {
                //     print("🟧 [RESTART_FEED_SUMMARY] Fed \(buffersFeToRenderer) buffers, total duration: \(String(format: "%.3f", totalDurationFed))s to renderer")
                // }
            } else {
                throttledBufferLog("⏳ RESTART HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", threshold))s)", throttleKey: "restart_holding_buffers", throttleInterval: 2.0)
            }
            emitDiagnosticsIfNeeded(context: "restart_feed")
            if !didStart {
                setSynchronizerRate(rate, time: time, context: "restart_initial")
                didStart = true
            }

            if !enqueuedAny,
               audioRenderer.isReadyForMoreMediaData,
               !(receiveComplete && (audioFileStream?.parsingComplete == true))
            {
                if !isBuffering { 
                    isBuffering = true
                    bufferLog("🔴 RESTART REQUEST DETECTED BUFFERING - No buffers available to enqueue")

                    // CRITICAL FIX: Pause the synchronizer to prevent time advancement during buffering
                    audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                    bufferLog("⏸️ PAUSED SYNCHRONIZER - Stopped time progression during restart request buffering")

                    bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                                            bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                        onBuffering() 
                }
            } else {
                if isBuffering { 
                    isBuffering = false 
                    bufferLog("💚 RESTART REQUEST EXITED BUFFERING - Buffers available, enqueuedAny: \(enqueuedAny)")
                    // FIX: Always resume rate if paused
                    if audioSynchronizer.rate == 0 {
                        bufferLog("🎬 EXIT RESUME - Restarting synchronizer at rate \(desiredRate)")
                        setSynchronizerRate(desiredRate, time: audioSynchronizer.currentTime(), context: "exitBuffering")
                        bufferLog("✅ EXIT RESUME - Applied desired rate \(desiredRate), actual rate: \(audioSynchronizer.rate)")
                        onPlaying()
                    }
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
        let currentRate = audioSynchronizer.rate
        let initialBufferThreshold: Double = bufferThreshold(for: currentRate) // Require consistent buffer before starting
        let hasEnoughBuffer = audioBuffersQueue.duration.seconds >= initialBufferThreshold
        
        // Only start if we have enough buffer OR the stream is complete with any data
        let shouldStart = (hasSufficientSystemData && hasEnoughBuffer) || (dataComplete && !audioBuffersQueue.isEmpty)
        
        if shouldStart {
            bufferLog("🎯 STARTING PLAYBACK - Conditions met (sufficient: \(hasSufficientSystemData), buffer: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, dataComplete: \(dataComplete))")
            // Resume from current synchronizer time to avoid jumping to zero
            let resumeTime = audioSynchronizer.currentTime()
            setSynchronizerRate(desiredRate, time: resumeTime, context: "startPlayback")
            bufferLog("✅ STARTED PLAYBACK - Applied desired rate \(desiredRate), actual rate: \(audioSynchronizer.rate)")
            didStart = true
            isBuffering = false
            bufferLog("🎬 [STATE] Calling onPlaying() - UI should show playing state")
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
        
        // RECOVERY THRESHOLD: Use same threshold as initial playback
        // The recovery threshold should match the initial playback threshold
        // to avoid getting stuck in buffering when we have sufficient buffer
        let recoveryRate = desiredRate // Use desired rate, not current rate (which is 0.0)
        let minimumBufferThreshold: Double = bufferThreshold(for: recoveryRate)
        
        bufferLog("🔍 FORCE EXIT CHECK - hasBuffers: \(hasBuffers), hasSufficientData: \(hasSufficientData), queueDuration: \(String(format: "%.2f", queueDuration))s, currentTime: \(String(format: "%.2f", currentTime))s, bufferAhead: \(String(format: "%.2f", bufferAhead))s")
        bufferLog("📊 PKG_FORCE_EXIT - Queue: \(String(format: "%.2f", queueDuration))s total | Ahead: \(String(format: "%.2f", bufferAhead))s | Player: \(String(format: "%.2f", currentTime))s | Threshold: \(String(format: "%.1f", minimumBufferThreshold))s | isEmpty: \(audioBuffersQueue.isEmpty)")
        
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
                // Apply desired rate directly - no need for 1.0x intermediate step
                audioSynchronizer.setRate(desiredRate, time: audioSynchronizer.currentTime())
                bufferLog("✅ FORCE RESUME - Applied desired rate \(desiredRate), actual rate: \(audioSynchronizer.rate)")
            }
            
            // CRITICAL: Always notify UI that we're playing when exiting buffering
            bufferLog("🎬 [STATE] Calling onPlaying() - UI should show playing state")
            onPlaying()
            
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
        
        // throttledBufferLog("🔄 HANDLING MEDIA DATA REQUEST - Queue size: \(audioBuffersQueue.isEmpty ? 0 : 1), isReady: \(renderer.isReadyForMoreMediaData)", throttleKey: "media_request", throttleInterval: 2.0)
        
        var enqueuedAny = false
        // Only feed buffers to renderer if synchronizer is actually playing or we have sufficient buffer
        let currentRate = audioSynchronizer?.rate ?? 1.0
        let threshold = bufferThreshold(for: currentRate)
        let shouldFeedRenderer = audioSynchronizer?.rate != 0 || audioBuffersQueue.duration.seconds >= threshold
        
        if shouldFeedRenderer {
            var buffersFeToRenderer = 0
            var totalDurationFed: Double = 0
            
            while let buffer = audioBuffersQueue.peek(), renderer.isReadyForMoreMediaData {
                let bufferDuration = buffer.duration.seconds
                let bufferStart = buffer.presentationTimeStamp.seconds
                let bufferEnd = bufferStart + bufferDuration
                let rendererReadyState = renderer.isReadyForMoreMediaData
                
                // print("🟨 [RENDERER_FEED] Feeding buffer: \(String(format: "%.3f", bufferDuration))s [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Renderer ready: \(rendererReadyState)")
                
                renderer.enqueue(buffer)
                audioBuffersQueue.removeFirst()
                onDurationChanged(audioBuffersQueue.duration)
                enqueuedAny = true
                buffersFeToRenderer += 1
                totalDurationFed += bufferDuration
            }
            
            // if buffersFeToRenderer > 0 {
            //     print("🟨 [RENDERER_FEED_SUMMARY] Fed \(buffersFeToRenderer) buffers, total duration: \(String(format: "%.3f", totalDurationFed))s to renderer")
            // }
        } else {
            throttledBufferLog("⏳ HANDLE HOLDING BUFFERS - Waiting for sufficient buffer before feeding renderer (current: \(String(format: "%.2f", audioBuffersQueue.duration.seconds))s, threshold: \(String(format: "%.1f", threshold))s)", throttleKey: "handle_holding_buffers", throttleInterval: 2.0)
        }
        
        // If we successfully enqueued data and synchronizer is stopped, start it
        if enqueuedAny && synchronizer.rate == 0 {
            bufferLog("🎬 STARTING PLAYBACK - Enqueued data and synchronizer was stopped")
            // Resume exactly from the current synchronizer time to avoid jumps
            let resumeTime = synchronizer.currentTime()
            synchronizer.setRate(desiredRate, time: resumeTime)
            bufferLog("✅ STARTED PLAYBACK - Applied desired rate \(desiredRate), actual rate: \(synchronizer.rate)")
            isBuffering = false
            bufferLog("🎬 [STATE] Calling onPlaying() - UI should show playing state")
            onPlaying()
        } else if enqueuedAny {
            // bufferLog("📤 ENQUEUED DATA - Synchronizer running at rate: \(synchronizer.rate)")
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
                // Apply desired rate directly
                synchronizer.setRate(desiredRate, time: .zero)
                bufferLog("✅ PIPELINE RESTART - Applied desired rate \(desiredRate), actual rate: \(synchronizer.rate)")
                
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
                let currentRate = audioSynchronizer.rate
                let syncCurrentTime = audioSynchronizer.currentTime().seconds
                
                // Event-driven anomalies only
                if currentTime > queueDuration + 0.01 { // 10ms tolerance
                    print("🚨 [TIME_OVERSHOOT] Player time \(String(format: "%.3f", currentTime))s > Queue duration \(String(format: "%.3f", queueDuration))s | Overshoot: +\(String(format: "%.3f", currentTime - queueDuration))s | Rate: \(currentRate)x | SyncTime: \(String(format: "%.3f", syncCurrentTime))s")
                }
                let timeDiff = abs(currentTime - syncCurrentTime)
                if timeDiff > 0.1 { // 100ms discrepancy
                    print("🚨 [TIME_MISMATCH] ObservedTime: \(String(format: "%.3f", currentTime))s vs SyncTime: \(String(format: "%.3f", syncCurrentTime))s | Diff: \(String(format: "%.3f", timeDiff))s | Rate: \(currentRate)x")
                }
                let minimumBufferThreshold: Double = bufferThreshold(for: currentRate) // Dynamic threshold based on rate
                let rendererHasData = audioRenderer.hasSufficientMediaDataForReliablePlaybackStart

                // Edge: renderer readiness flip
                if lastRendererReady == nil || lastRendererReady != rendererHasData {
                    print("🟪 [RENDERER_READY] \(rendererHasData)")
                    lastRendererReady = rendererHasData
                }
                // Edge: buffer ahead below threshold flip
                let isBelowThreshold = bufferAhead < minimumBufferThreshold
                if lastBufferAheadBelowThreshold == nil || lastBufferAheadBelowThreshold != isBelowThreshold {
                    print("🟪 [BUFFER_LEVEL] belowThreshold=\(isBelowThreshold) ahead=\(String(format: "%.2f", bufferAhead))s threshold=\(String(format: "%.1f", minimumBufferThreshold))s")
                    lastBufferAheadBelowThreshold = isBelowThreshold
                }
                // Edge: rate change (already handled elsewhere, but ensure emitted if missed)
                if lastLoggedRate == nil || lastLoggedRate != currentRate {
                    print("🟪 [RATE_STATE] rate=\(currentRate)x time=\(String(format: "%.3f", syncCurrentTime))s")
                    lastLoggedRate = currentRate
                }
                
                // Check if we're running low on buffer OR completely caught up
                // Add hysteresis: only trigger buffering if significantly below threshold
                // At 2x speed, need larger gap to prevent rapid cycling
                let bufferingHysteresis = max(1.0, Double(currentRate) * 0.75)  // Scale with playback rate
                let isRunningLowOnBuffer = bufferAhead <= (minimumBufferThreshold - bufferingHysteresis)
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
                            
                            // Pause the synchronizer at the current position to prevent UI jump to 0
                            audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                            bufferLog("⏸️ PAUSED SYNCHRONIZER - Preserved timebase at current position during buffering")
                            
                            bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                                            bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
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
                        
                        // Pause the synchronizer at the current position to prevent UI jump to 0
                        audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                        bufferLog("⏸️ PAUSED SYNCHRONIZER - Preserved timebase at current position (preemptive)")
                        
                        bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                                            bufferLog("🌀 [STATE] Calling onBuffering() - UI should show buffering state")
                        onBuffering()
                        
                        // Try to recover after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.forceExitBufferingIfPossible()
                        }
                    }
                } else {
                    // Normal playback path: update time continuously
                    onTimeChanged(time)
                }
            } else {
                if isBuffering { 
                    isBuffering = false
                    bufferLog("✅ EXITED BUFFERING - Player has available buffer ahead (time: \(String(format: "%.2f", time.seconds))s)")
                    
                    // Resume the synchronizer at the desired rate
                    if let audioSynchronizer = audioSynchronizer {
                        // Apply desired rate directly
                        audioSynchronizer.setRate(desiredRate, time: .zero)
                        bufferLog("▶️ RESUMED SYNCHRONIZER - Restarting playback from zero at rate \(desiredRate), actual rate: \(audioSynchronizer.rate)")
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
        audioStreamDescription = asbd
        let formatLabel = formatFourCC(asbd.mFormatID)
        bufferLog("🎧 RECEIVED AUDIO DESCRIPTION - Format: \(formatLabel) (\(asbd.mFormatID)), Channels: \(asbd.mChannelsPerFrame), SampleRate: \(asbd.mSampleRate), FramesPerPacket: \(asbd.mFramesPerPacket)")
        if asbd.mFormatID == kAudioFormatMPEGLayer3 {
            bufferLog("💽 MP3 FORMAT DETECTED - Padding diagnostics enabled for this stream")
        }
        
        // Create and setup audio renderer and synchronizer
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = initialVolume
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        
        // CRITICAL FIX: Initialize synchronizer timebase but keep it STOPPED
        // The timebase should not advance until we explicitly start playback
        
        // Step 1: Initialize with rate 0.0 to prevent auto-advancement
        synchronizer.rate = 0.0
        
        // Step 2: Initialize timebase at zero but keep stopped
        synchronizer.setRate(0.0, time: CMTime.zero)
        
        // Step 3: Verify timebase initialization but expect it to stay at zero
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self = self else { return }
            let verificationTime = synchronizer.currentTime()
            bufferLog("🔧 TIMEBASE VERIFICATION - currentTime after init: \(verificationTime.seconds)s (should stay near 0.0)")
            
            // Log if timebase is advancing when it shouldn't be
            if verificationTime.seconds > 0.1 {
                bufferLog("⚠️ TIMEBASE AUTO-ADVANCING - This may cause timing issues! Time: \(verificationTime.seconds)s")
            }
        }
        
        bufferLog("🔧 SYNCHRONIZER TIMEBASE INITIALIZED - setRate(0.0, time: CMTime.zero) - timebase stopped until playback starts")
        
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        do {
            audioBuffersQueue = try AudioBuffersQueue(audioDescription: asbd)
        } catch {
            bufferLog("❌ FAILED TO CREATE AudioBuffersQueue - Error: \(error)")
            onError(AudioPlayerError.other(error))
            return
        }
        
        bufferLog("🎬 AUDIO RENDERER CREATED - Starting media data requests")
        observeRenderer(renderer, synchronizer: synchronizer)
        startRequestingMediaData(renderer)
    }
    
    private func handlePacketTableInfo(
        _ info: AudioFilePacketTableInfo?,
        propertyID: AudioFilePropertyID,
        status: OSStatus
    ) {
        if let cachedStatus = packetInfoStatusCache[propertyID],
           cachedStatus == status,
           status != noErr {
            return
        }
        packetInfoStatusCache[propertyID] = status
        
        guard status == noErr, let info else {
            bufferLog("ℹ️ PACKET TABLE INFO UNAVAILABLE (\(propertyName(for: propertyID))) - status: \(osStatusDescription(status))")
            return
        }
        
        if let existingInfo = packetTableInfo,
           packetTableInfoEquals(existingInfo, info) {
            return
        }
        
        packetTableInfo = info
        logPacketTableInfo(info, sourceProperty: propertyID)
        logCumulativeFrameStats(context: "packetTableInfo")
        logPaddingSummaryIfPossible(reason: "packetTableInfo")
    }
    
    private struct TrimmedPacketBatch {
        let bytesPointer: UnsafeRawPointer
        let byteCount: UInt32
        let packetsPointer: UnsafeMutablePointer<AudioStreamPacketDescription>?
        let packetCount: UInt32
        let trimFramesAtEnd: Int
    }

    private func applyChunkBudgets(
        bytes: UnsafeRawPointer,
        byteCount: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?,
        packetCount: UInt32
    ) -> TrimmedPacketBatch? {
        guard !chunkBudgets.isEmpty else { return nil }
        guard let asbd = audioStreamDescription else { return nil }

        var budget = chunkBudgets[0]
        var effectiveBytesPointer = bytes
        var effectiveByteCount = byteCount
        var effectivePacketsPointer = packets
        var effectivePacketCount = packetCount

        var leadingBytesTrimmed = 0
        var leadingPacketsTrimmed = 0

        func framesAndSize(forPacketAt offset: Int) -> (frames: Int, byteSize: Int)? {
            if let pointer = packets {
                let packetDesc = pointer.advanced(by: offset).pointee
                let size = Int(packetDesc.mDataByteSize)
                let frames: Int
                if packetDesc.mVariableFramesInPacket > 0 {
                    frames = Int(packetDesc.mVariableFramesInPacket)
                } else if asbd.mFramesPerPacket > 0 {
                    frames = Int(asbd.mFramesPerPacket)
                } else {
                    return nil
                }
                guard size > 0 && frames > 0 else { return nil }
                return (frames, size)
            } else {
                guard asbd.mFramesPerPacket > 0 else { return nil }
                let frames = Int(asbd.mFramesPerPacket)
                let size: Int
                if asbd.mBytesPerPacket > 0 {
                    size = Int(asbd.mBytesPerPacket)
                } else if packetCount > 0 {
                    size = Int(byteCount) / Int(packetCount)
                } else {
                    return nil
                }
                guard size > 0 else { return nil }
                return (frames, size)
            }
        }

        while budget.leadingFramesRemaining > 0,
              effectivePacketCount > 0 {
            guard let packetInfo = framesAndSize(forPacketAt: leadingPacketsTrimmed) else {
                bufferLog("⚠️ [CHUNK_TRIM] Unable to resolve packet info while trimming leading frames for chunk \(budget.chunkIndex)")
                break
            }

            if budget.leadingFramesRemaining >= packetInfo.frames {
                budget.leadingFramesRemaining -= packetInfo.frames
                leadingBytesTrimmed += packetInfo.byteSize
                leadingPacketsTrimmed += 1
                effectivePacketCount -= 1
                effectiveByteCount = UInt32(max(Int(effectiveByteCount) - packetInfo.byteSize, 0))
            } else {
                // Partial packet priming trim not supported for AAC; fall back to attachments
                bufferLog("⚠️ [CHUNK_TRIM] Partial leading trim required for chunk \(budget.chunkIndex). Using attachment fallback.")
                break
            }
        }

        if leadingBytesTrimmed > 0 {
            effectiveBytesPointer = bytes.advanced(by: leadingBytesTrimmed)
            if let pointer = packets {
                effectivePacketsPointer = pointer.advanced(by: leadingPacketsTrimmed)
            }
            if let packetPointer = effectivePacketsPointer {
                var pointer = packetPointer
                let trimAmount = Int64(leadingBytesTrimmed)
                for _ in 0..<Int(effectivePacketCount) {
                    let currentOffset = pointer.pointee.mStartOffset
                    pointer.pointee.mStartOffset = max(0, currentOffset - trimAmount)
                    pointer = pointer.advanced(by: 1)
                }
            }
            bufferLog("✂️ [CHUNK_TRIM] Trimmed \(leadingBytesTrimmed) leading bytes across \(leadingPacketsTrimmed) packets for chunk \(budget.chunkIndex) (remaining leading frames: \(budget.leadingFramesRemaining))")
        }

        guard effectivePacketCount > 0, effectiveByteCount > 0 else {
            chunkBudgets[0] = budget
            if budget.leadingFramesRemaining <= 0 && (budget.playableFramesRemaining ?? 0) == 0 {
                chunkBudgets.removeFirst()
                bufferLog("✅ [CHUNK_TRIM] Chunk \(budget.chunkIndex) fully trimmed (no payload in this batch)")
            }
            return TrimmedPacketBatch(
                bytesPointer: effectiveBytesPointer,
                byteCount: effectiveByteCount,
                packetsPointer: effectivePacketsPointer,
                packetCount: effectivePacketCount,
                trimFramesAtEnd: 0
            )
        }

        var trimFramesAtEnd = 0
        if var playableRemaining = budget.playableFramesRemaining {
            var packetInfos: [(frames: Int, byteSize: Int)] = []
            packetInfos.reserveCapacity(Int(effectivePacketCount))
            for index in 0..<Int(effectivePacketCount) {
                let info: (frames: Int, byteSize: Int)?
                if let pointer = effectivePacketsPointer {
                    let packetDesc = pointer.advanced(by: index).pointee
                    let size = Int(packetDesc.mDataByteSize)
                    let frames: Int
                    if packetDesc.mVariableFramesInPacket > 0 {
                        frames = Int(packetDesc.mVariableFramesInPacket)
                    } else if asbd.mFramesPerPacket > 0 {
                        frames = Int(asbd.mFramesPerPacket)
                    } else {
                        info = nil
                        packetInfos = []
                        break
                    }
                    guard size > 0, frames > 0 else {
                        info = nil
                        packetInfos = []
                        break
                    }
                    info = (frames, size)
                } else {
                    guard asbd.mFramesPerPacket > 0 else {
                        info = nil
                        packetInfos = []
                        break
                    }
                    let frames = Int(asbd.mFramesPerPacket)
                    let size: Int
                    if asbd.mBytesPerPacket > 0 {
                        size = Int(asbd.mBytesPerPacket)
                    } else if effectivePacketCount > 0 {
                        size = Int(effectiveByteCount) / Int(effectivePacketCount)
                    } else {
                        info = nil
                        packetInfos = []
                        break
                    }
                    guard size > 0 else {
                        info = nil
                        packetInfos = []
                        break
                    }
                    info = (frames, size)
                }

                if let packet = info {
                    packetInfos.append(packet)
                } else {
                    bufferLog("⚠️ [CHUNK_TRIM] Unable to resolve packet info for chunk \(budget.chunkIndex); skipping playable trimming this batch")
                    packetInfos.removeAll()
                    break
                }
            }

            var keepCount = packetInfos.count
            if !packetInfos.isEmpty {
                keepCount = 0
                for packet in packetInfos {
                    if playableRemaining > packet.frames {
                        playableRemaining -= packet.frames
                        keepCount += 1
                        continue
                    } else if playableRemaining == packet.frames {
                        playableRemaining = 0
                        keepCount += 1
                        let trailingPacketsToDrop = packetInfos.count - keepCount
                        if trailingPacketsToDrop > 0 {
                            let bytesToDrop = packetInfos.suffix(trailingPacketsToDrop).reduce(0) { $0 + $1.byteSize }
                            effectivePacketCount = UInt32(max(Int(effectivePacketCount) - trailingPacketsToDrop, 0))
                            effectiveByteCount = UInt32(max(Int(effectiveByteCount) - bytesToDrop, 0))
                        }
                        break
                    } else {
                        let excess = packet.frames - playableRemaining
                        trimFramesAtEnd = min(excess, budget.trailingPaddingFrames)
                        if excess > budget.trailingPaddingFrames {
                            bufferLog("⚠️ [CHUNK_TRIM] Excess frames (\(excess)) exceeded trailing padding (\(budget.trailingPaddingFrames)) for chunk \(budget.chunkIndex); clamping trim.")
                        }
                        playableRemaining = 0
                        keepCount += 1
                        let trailingPacketsToDrop = packetInfos.count - keepCount
                        if trailingPacketsToDrop > 0 {
                            let bytesToDrop = packetInfos.suffix(trailingPacketsToDrop).reduce(0) { $0 + $1.byteSize }
                            effectivePacketCount = UInt32(max(Int(effectivePacketCount) - trailingPacketsToDrop, 0))
                            effectiveByteCount = UInt32(max(Int(effectiveByteCount) - bytesToDrop, 0))
                        }
                        break
                    }
                }
            }

            if packetInfos.isEmpty {
                chunkBudgets[0] = budget
            } else {
                budget.playableFramesRemaining = max(playableRemaining, 0)
                if playableRemaining == 0 {
                    bufferLog("✅ [CHUNK_TRIM] Chunk \(budget.chunkIndex) payload complete (frames consumed ~\(budget.totalPlayableFrames ?? -1))")
                    chunkBudgets.removeFirst()
                } else {
                    chunkBudgets[0] = budget
                }
            }
        } else {
            chunkBudgets[0] = budget
        }

        return TrimmedPacketBatch(
            bytesPointer: effectiveBytesPointer,
            byteCount: effectiveByteCount,
            packetsPointer: effectivePacketsPointer,
            packetCount: effectivePacketCount,
            trimFramesAtEnd: trimFramesAtEnd
        )
    }

    private func handleAudioStreamPackets(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        // bufferLog("🎧 RECEIVED \(numberOfPackets) PACKETS - \(numberOfBytes) bytes")

        guard let audioBuffersQueue = self.audioBuffersQueue else {
            bufferLog("❌ PACKETS DROPPED - No AudioBuffersQueue")
            return
        }

        var effectiveBytesPointer = bytes
        var effectiveByteCount = numberOfBytes
        var effectivePacketsPointer = packets
        var effectivePacketCount = numberOfPackets

        var trimFramesAtEnd = 0
        if let trimmed = applyChunkBudgets(
            bytes: effectiveBytesPointer,
            byteCount: effectiveByteCount,
            packets: effectivePacketsPointer,
            packetCount: effectivePacketCount
        ) {
            effectiveBytesPointer = trimmed.bytesPointer
            effectiveByteCount = trimmed.byteCount
            effectivePacketsPointer = trimmed.packetsPointer
            effectivePacketCount = trimmed.packetCount
            trimFramesAtEnd = trimmed.trimFramesAtEnd

            if effectiveByteCount == 0 || effectivePacketCount == 0 {
                bufferLog("✂️ [CHUNK_TRIM] Packet batch fully consumed by trim budgets; skipping enqueue")
                return
            }
        }

        if let asbd = audioStreamDescription,
           asbd.mFormatID == kAudioFormatMPEGLayer3,
           asbd.mSampleRate > 0 {
            if let framesInBatch = framesFromPackets(
                numberOfPackets: effectivePacketCount,
                packets: effectivePacketsPointer,
                asbd: asbd
            ) {
                totalPacketFramesReceived += framesInBatch
                totalPacketBatches += 1

                if shouldLogPacketBatch(batch: totalPacketBatches) {
                    let batchSeconds = framesToSecondsString(framesInBatch, sampleRate: asbd.mSampleRate)
                    let totalSeconds = framesToSecondsString(totalPacketFramesReceived, sampleRate: asbd.mSampleRate)
                    bufferLog("🧮 FRAME BATCH #\(totalPacketBatches) - +\(framesInBatch) frames (\(batchSeconds)s); cumulative \(totalPacketFramesReceived) frames (\(totalSeconds)s)")
                }

                if effectivePacketsPointer == nil, !missingPacketDescriptionsLogged {
                    missingPacketDescriptionsLogged = true
                    bufferLog("ℹ️ PACKET DESCRIPTIONS ABSENT - Assuming \(asbd.mFramesPerPacket) frames/packet; trailing padding detection may be approximate.")
                }

                logCumulativeFrameStats(context: "packets_batch \(totalPacketBatches)")
                logPaddingSummaryIfPossible(reason: "packets_batch")
            } else if !frameComputationFallbackLogged {
                frameComputationFallbackLogged = true
                bufferLog("⚠️ FRAME COUNT UNAVAILABLE - framesPerPacket=0 and no packet descriptions; cannot evaluate MP3 padding.")
            }
        }

        do {
                    try audioBuffersQueue.enqueue(
                numberOfBytes: effectiveByteCount,
                bytes: effectiveBytesPointer,
                numberOfPackets: effectivePacketCount,
                        packets: effectivePacketsPointer,
                        trimFramesAtEnd: trimFramesAtEnd > 0 ? trimFramesAtEnd : nil
            )
                    if trimFramesAtEnd > 0,
                       let sampleRate = audioStreamDescription?.mSampleRate,
                       sampleRate > 0 {
                        let seconds = Double(trimFramesAtEnd) / sampleRate
                        bufferLog("✂️ [CHUNK_TRIM] Requested trailing trim of \(trimFramesAtEnd) frames (\(String(format: "%.6f", seconds))s)")
                    }

            let newDuration = audioBuffersQueue.duration.seconds
            let currentPlayerTime = audioSynchronizer?.currentTime().seconds ?? 0.0
            let newBufferAhead = newDuration - currentPlayerTime
            // bufferLog("✅ ENQUEUED PACKETS - Queue duration: \(String(format: "%.2f", newDuration))s, isEmpty: \(audioBuffersQueue.isEmpty)")
            // bufferLog("📊 PKG_ENQUEUE - Queue: \(String(format: "%.2f", newDuration))s total | Ahead: \(String(format: "%.2f", newBufferAhead))s | Player: \(String(format: "%.2f", currentPlayerTime))s")
            onDurationChanged(audioBuffersQueue.duration)

            if isBuffering {
                bufferLog("🚑 NEW BUFFER ARRIVED DURING BUFFERING - Attempting force exit")
                forceExitBufferingIfPossible()
            }

        } catch {
            bufferLog("❌ FAILED TO ENQUEUE PACKETS - Error: \(error)")
            onError(AudioPlayerError.other(error))
        }
    }


    // MARK: - Padding diagnostics helpers

    private func framesFromPackets(
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?,
        asbd: AudioStreamBasicDescription
    ) -> Int64? {
        if numberOfPackets == 0 { return 0 }

        if let packets = packets {
            let descriptions = UnsafeBufferPointer(start: packets, count: Int(numberOfPackets))
            var totalFrames: Int64 = 0

            for description in descriptions {
                if description.mVariableFramesInPacket > 0 {
                    totalFrames += Int64(description.mVariableFramesInPacket)
                } else if asbd.mFramesPerPacket > 0 {
                    totalFrames += Int64(asbd.mFramesPerPacket)
                } else {
                    return nil
                }
            }

            return totalFrames
        } else {
            guard asbd.mFramesPerPacket > 0 else { return nil }
            return Int64(numberOfPackets) * Int64(asbd.mFramesPerPacket)
        }
    }

    private func shouldLogPacketBatch(batch: Int64) -> Bool {
        batch <= 5 || batch % 25 == 0
    }

    private func framesToSecondsString(_ frames: Int64, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "n/a" }
        let seconds = Double(frames) / sampleRate
        return String(format: "%.6f", seconds)
    }

    private func describeFrames(_ frames: Int64?, sampleRate: Double) -> String {
        guard let frames else { return "unknown" }
        let seconds = framesToSecondsString(frames, sampleRate: sampleRate)
        return "\(frames) frames (\(seconds)s)"
    }

    private func logPacketTableInfo(_ info: AudioFilePacketTableInfo, sourceProperty: AudioFilePropertyID) {
        let primingRaw = Int64(info.mPrimingFrames)
        let remainderRaw = Int64(info.mRemainderFrames)
        let validRaw = info.mNumberValidFrames

        bufferLog("🧾 PACKET TABLE INFO (\(propertyName(for: sourceProperty))) - priming: \(primingRaw) frames, remainder: \(remainderRaw) frames, valid: \(validRaw) frames")

        if let asbd = audioStreamDescription, asbd.mSampleRate > 0 {
            let sampleRate = asbd.mSampleRate
            let primingDescription = describeFrames(info.mPrimingFrames >= 0 ? Int64(info.mPrimingFrames) : nil, sampleRate: sampleRate)
            let remainderDescription = describeFrames(info.mRemainderFrames >= 0 ? Int64(info.mRemainderFrames) : nil, sampleRate: sampleRate)
            let validDescription = describeFrames(info.mNumberValidFrames >= 0 ? info.mNumberValidFrames : nil, sampleRate: sampleRate)
            bufferLog("🧾 PACKET TABLE INFO (seconds) - priming: \(primingDescription), remainder: \(remainderDescription), valid: \(validDescription)")
        } else {
            bufferLog("🧾 PACKET TABLE INFO - Sample rate unavailable; cannot convert padding frames to seconds yet")
        }

        if info.mPrimingFrames > 0 || info.mRemainderFrames > 0 {
            bufferLog("⚠️ PADDING METADATA PRESENT - Leading priming frames: \(info.mPrimingFrames), trailing remainder frames: \(info.mRemainderFrames)")
        } else if info.mPrimingFrames == 0 && info.mRemainderFrames == 0 {
            bufferLog("✅ PACKET TABLE INDICATES NO MP3 PADDING - Priming and remainder frames both zero")
        } else if info.mPrimingFrames < 0 || info.mRemainderFrames < 0 {
            bufferLog("ℹ️ PACKET TABLE DOES NOT REPORT PADDING - Priming (\(info.mPrimingFrames)) or remainder (\(info.mRemainderFrames)) frames marked as unknown")
        }
    }

    private func logCumulativeFrameStats(context: String) {
        guard let asbd = audioStreamDescription,
              asbd.mFormatID == kAudioFormatMPEGLayer3,
              asbd.mSampleRate > 0 else { return }

        let totalSeconds = framesToSecondsString(totalPacketFramesReceived, sampleRate: asbd.mSampleRate)

        if let info = packetTableInfo,
           info.mNumberValidFrames >= 0,
           info.mPrimingFrames >= 0,
           info.mRemainderFrames >= 0 {
            let primingFrames = Int64(info.mPrimingFrames)
            let remainderFrames = Int64(info.mRemainderFrames)
            let expectedTotal = info.mNumberValidFrames + primingFrames + remainderFrames
            let delta = totalPacketFramesReceived - expectedTotal
            bufferLog(
                "🧮 FRAME TALLY [\(context)] - observed \(totalPacketFramesReceived) frames (\(totalSeconds)s); expected \(expectedTotal) frames; delta \(delta) frames (\(framesToSecondsString(delta, sampleRate: asbd.mSampleRate))s)"
            )
        } else if let info = packetTableInfo {
            bufferLog(
                "🧮 FRAME TALLY [\(context)] - observed \(totalPacketFramesReceived) frames (\(totalSeconds)s); packet table present but contains unknown values (priming \(info.mPrimingFrames), remainder \(info.mRemainderFrames), valid \(info.mNumberValidFrames))"
            )
        } else {
            bufferLog("🧮 FRAME TALLY [\(context)] - observed \(totalPacketFramesReceived) frames (\(totalSeconds)s); packet table info pending")
        }
    }

    private func logPaddingSummaryIfPossible(reason: String) {
        guard !paddingSummaryLogged else { return }
        guard receiveComplete else { return }
        guard let asbd = audioStreamDescription, asbd.mSampleRate > 0 else { return }

        guard let info = packetTableInfo else {
            bufferLog("ℹ️ PADDING SUMMARY (\(reason)) - Stream finished but packet table info unavailable; cannot confirm MP3 padding.")
            paddingSummaryLogged = true
            return
        }

        guard info.mPrimingFrames >= 0,
              info.mRemainderFrames >= 0,
              info.mNumberValidFrames >= 0 else {
            bufferLog("ℹ️ PADDING SUMMARY (\(reason)) - Packet table contains unknown values (priming \(info.mPrimingFrames), remainder \(info.mRemainderFrames), valid \(info.mNumberValidFrames)); unable to compute final padding.")
            paddingSummaryLogged = true
            return
        }

        let sampleRate = asbd.mSampleRate
        let primingFrames = Int64(info.mPrimingFrames)
        let remainderFrames = Int64(info.mRemainderFrames)
        let validFrames = info.mNumberValidFrames
        let expectedTotal = validFrames + primingFrames + remainderFrames
        let delta = totalPacketFramesReceived - expectedTotal

        bufferLog(
            "🏁 PADDING SUMMARY (\(reason)) - priming \(describeFrames(primingFrames, sampleRate: sampleRate)), remainder \(describeFrames(remainderFrames, sampleRate: sampleRate)), valid \(describeFrames(validFrames, sampleRate: sampleRate)), observed \(totalPacketFramesReceived) frames (\(framesToSecondsString(totalPacketFramesReceived, sampleRate: sampleRate))s), delta \(delta) frames (\(framesToSecondsString(delta, sampleRate: sampleRate))s)"
        )

        if primingFrames > 0 || remainderFrames > 0 {
            bufferLog("⚠️ FINAL PADDING DETECTED - Encoder priming \(primingFrames) frames, trailing padding \(remainderFrames) frames")
        } else {
            bufferLog("✅ FINAL PADDING SUMMARY - Packet table reports zero priming and remainder frames")
        }

        paddingSummaryLogged = true
    }

    private func packetTableInfoEquals(_ lhs: AudioFilePacketTableInfo, _ rhs: AudioFilePacketTableInfo) -> Bool {
        lhs.mPrimingFrames == rhs.mPrimingFrames &&
        lhs.mRemainderFrames == rhs.mRemainderFrames &&
        lhs.mNumberValidFrames == rhs.mNumberValidFrames
    }

    private func propertyName(for propertyID: AudioFilePropertyID) -> String {
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            return "DataFormat"
        case kAudioFileStreamProperty_ReadyToProducePackets:
            return "ReadyToProducePackets"
        case kAudioFileStreamProperty_PacketTableInfo:
            return "PacketTableInfo"
        default:
            return String(format: "0x%08X", propertyID)
        }
    }

    private func osStatusDescription(_ status: OSStatus) -> String {
        if status == noErr { return "noErr" }
        let code = UInt32(bitPattern: status)
        var characters: [Character] = []
        var isPrintable = true

        for shift in stride(from: 24, through: 0, by: -8) {
            let value = (code >> UInt32(shift)) & 0xFF
            guard let scalar = UnicodeScalar(value), scalar.isASCII else {
                isPrintable = false
                break
            }
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                characters.append(Character(scalar))
            } else {
                isPrintable = false
                break
            }
        }

        if isPrintable, !characters.isEmpty {
            return "'\(String(characters))'"
        }

        return String(format: "0x%08X", code)
    }

    private func formatFourCC(_ value: UInt32) -> String {
        var characters: [Character] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            let component = (value >> UInt32(shift)) & 0xFF
            if let scalar = UnicodeScalar(component),
               scalar.isASCII,
               scalar.value >= 0x20,
               scalar.value <= 0x7E {
                characters.append(Character(scalar))
            } else {
                characters.append("?")
            }
        }
        return String(characters)
    }
}
