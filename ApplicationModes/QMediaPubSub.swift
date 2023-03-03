import SwiftUI
import CoreMedia

class QMediaPubSub: ApplicationModeBase {

    private static var streamIdMap: [UInt64: QMediaPubSub] = .init()

    private var qMedia: QMedia?
    private var identifierMapping: [UInt32: UInt64] = .init()

    private var videoSubscription: UInt64 = 0
    private var audioSubscription: UInt64 = 0

    private var sourcesByMediaType: [QMedia.CodecType: UInt8] = [:]

    override var root: AnyView {
        get { return .init(QMediaConfigCall(mode: self, callback: connect))}
        set { }
    }

    let streamCallback: SubscribeCallback = { streamId, mediaId, clientId, data, length, timestamp in
        guard let publisher = QMediaPubSub.streamIdMap[streamId] else {
            fatalError("Failed to find QMediaPubSub instance for stream: \(streamId))")
        }
        guard data != nil else { print("[QMediaPubSub] [Subscription \(streamId)] Data was nil"); return }

        // Get the codec out of the media ID.
        let rawCodec = mediaId >> 4
        guard let codec = QMedia.CodecType(rawValue: rawCodec) else {
            print("Unexpected codec type: \(rawCodec)")
            return
        }

        let mediaType: PipelineManager.MediaType
        switch codec {
        case .h264:
            mediaType = .video
        case .opus:
            mediaType = .audio
        }

        let unique: UInt32 = .init(clientId) << 24 | .init(mediaId)
        if publisher.pipeline!.decoders[unique] == nil {
            publisher.pipeline!.registerDecoder(identifier: unique, type: mediaType)
        }

        print("[QMediaPubSub] [Subscription \(streamId)] Got \(length) bytes")
        let buffer: MediaBufferFromSource = .init(source: UInt32(unique),
                                                  media: .init(buffer: .init(start: data, count: Int(length)),
                                                               timestampMs: UInt32(timestamp)))
        publisher.pipeline!.decode(mediaBuffer: buffer)
    }

    func connect(config: CallConfig) {
        guard qMedia == nil else { fatalError("Already connected") }
        qMedia = .init(address: .init(string: config.address)!, port: config.port)

        // Video.
        videoSubscription = qMedia!.addVideoStreamSubscribe(codec: .h264, callback: streamCallback)
        Self.streamIdMap[videoSubscription] = self
        print("[QMediaPubSub] Subscribed for video: \(videoSubscription)")

        // Audio.
        audioSubscription = qMedia!.addAudioStreamSubscribe(codec: .opus, callback: streamCallback)
        Self.streamIdMap[audioSubscription] = self
        print("[QMediaPubSub] Subscribed for audio: \(audioSubscription)")
    }

    override func createVideoEncoder(identifier: UInt32, width: Int32, height: Int32) {
        super.createVideoEncoder(identifier: identifier, width: width, height: height)

        let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: getUniqueCodecType(type: .h264),
                                                                 clientIdentifier: clientId)
        print("[QMediaPubSub] (\(identifier)) Video registered to publish stream: \(subscriptionId)")
        identifierMapping[identifier] = subscriptionId
    }

    override func createAudioEncoder(identifier: UInt32) {
        super.createAudioEncoder(identifier: identifier)

        let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: getUniqueCodecType(type: .opus),
                                                                 clientIdentifier: clientId)
        print("[QMediaPubSub] (\(identifier)) Audio registered to publish stream: \(subscriptionId)")
        identifierMapping[identifier] = subscriptionId
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        do {
            try data.dataBuffer!.withUnsafeMutableBytes { ptr in
                let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                var timestamp: CMTime = .init()
                do {
                    timestamp = try data.sampleTimingInfo(at: 0).presentationTimeStamp
                } catch {
                    print("[QMediaPubSub] Failed to fetch timestamp")
                }
                let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
                guard let streamId = self.identifierMapping[identifier] else {
                    print("[QMediaPubSub] Couldn't lookup stream id for media id: \(identifier)")
                    return
                }
                qMedia!.sendVideoFrame(mediaStreamId: streamId,
                                       buffer: unsafe,
                                       length: UInt32(data.dataBuffer!.dataLength),
                                       timestamp: UInt64(timestampMs),
                                       flag: false)
            }
        } catch {
            print("[QMediaPubSub] Failed to get bytes of encoded image")
        }
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        guard let streamId = identifierMapping[data.source] else {
            print("[QMediaPubSub] Couldn't lookup stream id for media id: \(data.source)")
            return
        }
        guard data.media.buffer.count > 0 else { fatalError() }
        qMedia!.sendAudio(mediaStreamId: streamId,
                          buffer: data.media.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          length: UInt32(data.media.buffer.count),
                          timestamp: UInt64(data.media.timestampMs))
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: frame, type: .video)
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: sample, type: .audio)
    }

    private func encodeSample(identifier: UInt32,
                              frame: CMSampleBuffer,
                              type: PipelineManager.MediaType) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            return
        }

        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }

    private func getUniqueCodecType(type: QMedia.CodecType) -> UInt8 {
        if sourcesByMediaType[type] == nil {
            sourcesByMediaType[type] = 0
        } else {
            sourcesByMediaType[type]! += 1
        }
        return type.rawValue << 4 | sourcesByMediaType[type]!
    }
}
