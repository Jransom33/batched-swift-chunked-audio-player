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
        let oldDuration = duration.seconds
        duration = buffer.presentationTimeStamp + buffer.duration
        let newDuration = duration.seconds
        let bufferStart = buffer.presentationTimeStamp.seconds
        let bufferEnd = bufferStart + buffer.duration.seconds
        
        print("🔧 [DURATION_UPDATE] Buffer [\(String(format: "%.3f", bufferStart))s → \(String(format: "%.3f", bufferEnd))s] | Duration: \(String(format: "%.3f", oldDuration))s → \(String(format: "%.3f", newDuration))s | Change: +\(String(format: "%.3f", newDuration - oldDuration))s")
    }
    
    private func updateDurationAfterRemoval() {
        // The duration should NOT change when buffers are consumed by the renderer
        // because the renderer still has that audio content available for playback.
        // The duration represents the total audio content that has been made available,
        // not just what's sitting in our local buffer queue.
        
        let oldDuration = duration.seconds
        
        // Only update duration if we have remaining buffers that extend beyond current duration
        if !buffers.isEmpty {
            if let lastAvailableBuffer = buffers.last {
                let potentialNewDuration = lastAvailableBuffer.presentationTimeStamp + lastAvailableBuffer.duration
                // Only extend duration, never reduce it
                if potentialNewDuration > duration {
                    duration = potentialNewDuration
                    print("🔧 [DURATION_EXTEND] Extended duration from \(String(format: "%.3f", oldDuration))s to \(String(format: "%.3f", duration.seconds))s based on remaining buffer")
                } else {
                    print("🔧 [DURATION_KEEP] Duration unchanged at \(String(format: "%.3f", oldDuration))s (remaining buffer doesn't extend beyond current)")
                }
            }
        } else {
            print("🔧 [DURATION_HOLD] Duration held at \(String(format: "%.3f", oldDuration))s (no remaining buffers, renderer still has content)")
        }
        // When buffers.isEmpty, keep duration unchanged - the renderer still has the content
    }

    private func withLock<T>(_ perform: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try perform()
    }
}
