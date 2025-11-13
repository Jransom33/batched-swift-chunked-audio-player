import AVFoundation
import AudioToolbox

final class AudioFileStream: Sendable {
    typealias ErrorCallback = @Sendable (_ error: AudioPlayerError) -> Void
    typealias ASBDCallback = @Sendable (_ asbd: AudioStreamBasicDescription) -> Void
    typealias PacketsCallback = @Sendable (
        _ numberOfBytes: UInt32,
        _ bytes: UnsafeRawPointer,
        _ numberOfPackets: UInt32,
        _ packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) -> Void
    typealias PacketTableInfoCallback = @Sendable (
        _ info: AudioFilePacketTableInfo?,
        _ sourceProperty: AudioFilePropertyID,
        _ status: OSStatus
    ) -> Void
    typealias MagicCookieCallback = @Sendable (_ magicCookie: Data?) -> Void

    private let receiveError: ErrorCallback
    private let receiveASBD: ASBDCallback
    private let receivePackets: PacketsCallback
    private let receivePacketTableInfo: PacketTableInfoCallback
    private let receiveMagicCookie: MagicCookieCallback

    private let syncQueue: DispatchQueue

    private(set) nonisolated(unsafe) var audioStreamID: AudioFileStreamID?
    private(set) nonisolated(unsafe) var fileTypeID: AudioFileTypeID?
    private(set) nonisolated(unsafe) var parsingComplete = false

    init(
        type: AudioFileTypeID? = nil,
        queue: DispatchQueue,
        receiveError: @escaping ErrorCallback,
        receiveASBD: @escaping ASBDCallback,
        receivePackets: @escaping PacketsCallback,
        receivePacketTableInfo: @escaping PacketTableInfoCallback = { _, _, _ in },
        receiveMagicCookie: @escaping MagicCookieCallback = { _ in }
    ) {
        self.fileTypeID = type
        self.syncQueue = queue
        self.receiveError = receiveError
        self.receiveASBD = receiveASBD
        self.receivePackets = receivePackets
        self.receivePacketTableInfo = receivePacketTableInfo
        self.receiveMagicCookie = receiveMagicCookie
    }

    func open() {
        let instance = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = AudioFileStreamOpen(instance, { instance, _, propertyID, _ in
            let stream = Unmanaged<AudioFileStream>.fromOpaque(instance).takeUnretainedValue()
            stream.onFileStreamPropertyReceived(propertyID: propertyID)
        }, { instance, numberBytes, numberPackets, bytes, packets in
            let stream = Unmanaged<AudioFileStream>.fromOpaque(instance).takeUnretainedValue()
            stream.onFileStreamPacketsReceived(
                numberOfBytes: numberBytes,
                bytes: bytes,
                numberOfPackets: numberPackets,
                packets: packets
            )
        }, fileTypeID ?? 0, &audioStreamID )
        if status != noErr { receiveError(.status(status)) }
        if audioStreamID == nil { receiveError(.streamNotOpened) }
    }

    func close() {
        guard let streamID = audioStreamID else { return }
        AudioFileStreamClose(streamID)
        audioStreamID = nil
    }

    func parseData(_ data: Data) {
        syncQueue.async { [weak self] in
            guard let self, let audioStreamID else { return }
            data.withUnsafeBytes { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                AudioFileStreamParseBytes(audioStreamID, UInt32(data.count), baseAddress, [])
            }
        }
    }

    func finishDataParsing() {
        syncQueue.async { [weak self] in
            guard let self, let audioStreamID else { return }
            AudioFileStreamParseBytes(audioStreamID, 0, nil, [])
            parsingComplete = true
        }
    }

    // MARK: - Private

    private func onFileStreamPropertyReceived(propertyID: AudioFilePropertyID) {
        guard let audioStreamID = audioStreamID else { return }
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            var asbdSize: UInt32 = 0
            var asbd = AudioStreamBasicDescription()
            let getInfoStatus = AudioFileStreamGetPropertyInfo(audioStreamID, propertyID, &asbdSize, nil)
            guard getInfoStatus == noErr else { return receiveError(.status(getInfoStatus)) }
            let getPropertyStatus = AudioFileStreamGetProperty(audioStreamID, propertyID, &asbdSize, &asbd)
            guard getPropertyStatus == noErr else { return receiveError(.status(getPropertyStatus)) }
            receiveASBD(asbd)
        case kAudioFileStreamProperty_ReadyToProducePackets:
            emitMagicCookie(audioStreamID: audioStreamID)
            fallthrough
        case kAudioFileStreamProperty_PacketTableInfo:
            emitPacketTableInfo(sourceProperty: propertyID, audioStreamID: audioStreamID)
        default:
            break
        }
    }

    private func onFileStreamPacketsReceived(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        receivePackets(numberOfBytes, bytes, numberOfPackets, packets)
    }

    private func emitPacketTableInfo(sourceProperty: AudioFilePropertyID, audioStreamID: AudioFileStreamID) {
        var propertySize: UInt32 = 0
        let propertyInfoStatus = AudioFileStreamGetPropertyInfo(
            audioStreamID,
            kAudioFileStreamProperty_PacketTableInfo,
            &propertySize,
            nil
        )
        guard propertyInfoStatus == noErr else {
            receivePacketTableInfo(nil, sourceProperty, propertyInfoStatus)
            return
        }
        guard propertySize == MemoryLayout<AudioFilePacketTableInfo>.size else {
            receivePacketTableInfo(nil, sourceProperty, kAudio_ParamError)
            return
        }

        var packetInfo = AudioFilePacketTableInfo()
        var actualSize = propertySize
        let propertyStatus = AudioFileStreamGetProperty(
            audioStreamID,
            kAudioFileStreamProperty_PacketTableInfo,
            &actualSize,
            &packetInfo
        )
        guard propertyStatus == noErr else {
            receivePacketTableInfo(nil, sourceProperty, propertyStatus)
            return
        }

        receivePacketTableInfo(packetInfo, sourceProperty, propertyStatus)
    }

    private func emitMagicCookie(audioStreamID: AudioFileStreamID) {
        var cookieSize: UInt32 = 0
        let infoStatus = AudioFileStreamGetPropertyInfo(
            audioStreamID,
            kAudioFileStreamProperty_MagicCookieData,
            &cookieSize,
            nil
        )

        guard infoStatus == noErr, cookieSize > 0 else {
            receiveMagicCookie(nil)
            return
        }

        var cookieData = Data(count: Int(cookieSize))
        let fetchStatus = cookieData.withUnsafeMutableBytes { pointer -> OSStatus in
            guard let baseAddress = pointer.baseAddress else { return kAudio_ParamError }
            var size = cookieSize
            return AudioFileStreamGetProperty(
                audioStreamID,
                kAudioFileStreamProperty_MagicCookieData,
                &size,
                baseAddress
            )
        }

        guard fetchStatus == noErr else {
            receiveMagicCookie(nil)
            return
        }

        receiveMagicCookie(cookieData)
    }
}
