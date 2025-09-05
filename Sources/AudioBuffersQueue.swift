import AVFoundation
import os

final class AudioBuffersQueue: Sendable {
    private let audioDescription: AudioStreamBasicDescription
    private nonisolated(unsafe) var allBuffers = [CMSampleBuffer]()
    private nonisolated(unsafe) var buffers = [CMSampleBuffer]()
    private let lock = NSLock()

    private(set) nonisolated(unsafe) var duration = CMTime.zero

    var isEmpty: Bool {
        withLock { buffers.isEmpty }
    }

    init(audioDescription: AudioStreamBasicDescription) {
        self.audioDescription = audioDescription
        self.duration = CMTime(value: 0, timescale: Int32(audioDescription.mSampleRate))
    }

    func enqueue(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) throws {
        try withLock {
            let queueSizeBefore = buffers.count
            let queueDurationBefore = duration.seconds
            
            guard let buffer = try makeSampleBuffer(
                from: Data(bytes: bytes, count: Int(numberOfBytes)),
                packetCount: numberOfPackets,
                packetDescriptions: packets
            ) else { return }
            
            // Diagnostics: count enqueued seconds
            let seconds = buffer.duration.seconds
            let bufferStart = buffer.presentationTimeStamp.seconds
            let bufferEnd = bufferStart + seconds
            
            updateDuration(for: buffer)
            buffers.append(buffer)
            allBuffers.append(buffer)
            
            let queueSizeAfter = buffers.count
            let queueDurationAfter = duration.seconds
            
            print("🟦 [QUEUE_ADD] Buffer: \(String(format: "%.3f", seconds))s [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Queue: \(queueSizeBefore) → \(queueSizeAfter) buffers | Total: \(String(format: "%.2f", queueDurationBefore))s → \(String(format: "%.2f", queueDurationAfter))s")
            
            // Emit minimal log only when seconds is non-trivial
            if seconds > 0.0 {
                // no-op placeholder for external diag aggregation
            }
        }
    }

    func peek() -> CMSampleBuffer? {
        withLock { buffers.first }
    }

    func dequeue() -> CMSampleBuffer? {
        withLock {
            if buffers.isEmpty { return nil }
            
            let queueSizeBefore = buffers.count
            let queueDurationBefore = duration.seconds
            
            let buffer = buffers.removeFirst()
            let bufferDuration = buffer.duration.seconds
            let bufferStart = buffer.presentationTimeStamp.seconds
            let bufferEnd = bufferStart + bufferDuration
            
            let queueSizeAfter = buffers.count
            let queueDurationAfter = duration.seconds
            
            print("🟥 [QUEUE_REMOVE] Buffer: \(String(format: "%.3f", bufferDuration))s [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Queue: \(queueSizeBefore) → \(queueSizeAfter) buffers | Total: \(String(format: "%.2f", queueDurationBefore))s → \(String(format: "%.2f", queueDurationAfter))s")
            
            return buffer
        }
    }

    func removeFirst() {
        withLock {
            if buffers.isEmpty { return }
            
            let queueSizeBefore = buffers.count
            let queueDurationBefore = duration.seconds
            
            let buffer = buffers.removeFirst()
            let bufferDuration = buffer.duration.seconds
            let bufferStart = buffer.presentationTimeStamp.seconds
            let bufferEnd = bufferStart + bufferDuration
            
            // CRITICAL FIX: Update duration to reflect remaining buffers
            updateDurationAfterRemoval()
            
            let queueSizeAfter = buffers.count
            let queueDurationAfter = duration.seconds
            
            print("🟥 [QUEUE_REMOVE] Buffer: \(String(format: "%.3f", bufferDuration))s [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Queue: \(queueSizeBefore) → \(queueSizeAfter) buffers | Total: \(String(format: "%.2f", queueDurationBefore))s → \(String(format: "%.2f", queueDurationAfter))s")
        }
    }

    func removeAll() {
        withLock {
            allBuffers.removeAll()
            buffers.removeAll()
            duration = .zero
        }
    }

    func buffer(at time: CMTime) -> CMSampleBuffer? {
        withLock { allBuffers.first { $0.timeRange.containsTime(time) } }
    }

    func flush() {
        withLock { buffers.removeAll() }
    }

    func seek(to time: CMTime) {
        withLock {
            guard let index = allBuffers.enumerated().first(where: { _, buffer in
                buffer.timeRange.containsTime(time)
            })?.offset else { return }
            buffers = Array(allBuffers[index...])
        }
    }

    // MARK: - Private

    private func makeSampleBuffer(
        from data: Data,
        packetCount: UInt32,
        packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
    ) throws -> CMSampleBuffer? {
        guard let blockBuffer = try makeBlockBuffer(from: data) else { return nil }
        let formatDescription = try CMFormatDescription(audioStreamBasicDescription: audioDescription)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(packetCount),
            presentationTimeStamp: duration,
            packetDescriptions: packetDescriptions,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { throw AudioPlayerError.status(createStatus) }

        return sampleBuffer
    }

    private func makeBlockBuffer(from data: Data) throws -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr else { throw AudioPlayerError.status(createStatus) }
        guard let blockBuffer else { return nil }
        return try data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
            guard replaceStatus == noErr else { throw AudioPlayerError.status(replaceStatus) }

            return blockBuffer
        }
    }

    private func updateDuration(for buffer: CMSampleBuffer) {
        // For streaming audio, duration should represent the total accumulated audio
        // This is the end time of the latest buffer added, regardless of what's been consumed
        duration = buffer.presentationTimeStamp + buffer.duration
    }
    
    private func updateDurationAfterRemoval() {
        // CRITICAL FIX: Duration should represent actual available playback content
        if buffers.isEmpty {
            // When no buffers are available, duration should reflect the furthest point
            // we can actually play to based on what's been fed to the renderer
            // Keep the duration as the last buffer's end time since that content
            // is still available in the renderer's internal buffer
            // This prevents premature buffering when renderer has internal content
            
            // Duration stays the same - don't reduce it when buffers are consumed
            // The renderer has internal buffering that continues playback
        } else {
            // Duration should be the end time of the last available buffer
            if let lastAvailableBuffer = buffers.last {
                duration = lastAvailableBuffer.presentationTimeStamp + lastAvailableBuffer.duration
            }
        }
    }

    private func withLock<T>(_ perform: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try perform()
    }
}
