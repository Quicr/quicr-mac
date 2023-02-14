import SwiftUI
import CoreMedia

class QMediaPubSub: ApplicationModeBase {

    private static var streamIdMap: [UInt64: QMediaPubSub] = .init()

    private var qMedia: QMedia?
    private var identifierMapping: [UInt32: UInt64] = .init()

    override var root: AnyView {
        get { return .init(QMediaConfigCall(mode: self, callback: connect))}
        set { }
    }

    let streamCallback: SubscribeCallback = { streamId, data, length in
        guard let publisher = QMediaPubSub.streamIdMap[streamId] else {
            fatalError("Failed to find QMediaPubSub instance for stream: \(streamId))")
        }
        guard data != nil else { print("[QMediaPubSub] [Subscription \(streamId)] Data was nil"); return }
        print("[QMediaPubSub] [Subscription \(streamId)] Got \(length) bytes")
        let buffer: MediaBuffer = .init(identifier: UInt32(streamId),
                                        buffer: .init(start: .init(data), count: Int(length)),
                                        timestampMs: 0)
        publisher.pipeline!.decode(mediaBuffer: buffer)
    }

    func connect(config: CallConfig) {
        guard qMedia == nil else { fatalError("Already connected") }
        qMedia = .init(address: .init(string: config.address)!, port: config.port)

        // TODO: Where should the subscriptions go?

        // Video.
        let videoSubscription = qMedia!.addVideoStreamSubscribe(codec: .h264, callback: streamCallback)
        Self.streamIdMap[videoSubscription] = self
        pipeline!.registerDecoder(identifier: UInt32(videoSubscription), type: .video)
        print("[QMediaPubSub] Subscribed for video: \(videoSubscription)")

        // Audio.
        let audioSubscription = qMedia!.addAudioStreamSubscribe(codec: .opus, callback: streamCallback)
        Self.streamIdMap[audioSubscription] = self
        pipeline!.registerDecoder(identifier: UInt32(audioSubscription), type: .audio)
        print("[QMediaPubSub] Subscribed for audio: \(audioSubscription)")
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

    override func sendEncodedAudio(data: MediaBuffer) {
        guard let streamId = identifierMapping[data.identifier] else {
            print("[QMediaPubSub] Couldn't lookup stream id for media id: \(data.identifier)")
            return
        }
        guard data.buffer.count > 0 else { fatalError() }
        qMedia!.sendAudio(mediaStreamId: streamId,
                          buffer: data.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          length: UInt32(data.buffer.count),
                          timestamp: UInt64(data.timestampMs))
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: frame, type: .video) {
            let size = frame.formatDescription!.dimensions
            let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: .h264)
            print("[QMediaPubSub] (\(identifier)) Video registered to publish stream: \(subscriptionId)")
            identifierMapping[identifier] = subscriptionId
            pipeline!.registerEncoder(identifier: identifier, width: size.width, height: size.height)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: sample, type: .audio) {
            let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: .opus)
            print("[QMediaPubSub] (\(identifier)) Audio registered to publish stream: \(subscriptionId)")
            identifierMapping[identifier] = subscriptionId
            let encoder = LibOpusEncoder { media in
                let identified: MediaBuffer = .init(identifier: identifier, other: media)
                self.sendEncodedAudio(data: identified)
            }
            pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
            identifierMapping[identifier] = subscriptionId
        }
    }

    private func encodeSample(identifier: UInt32,
                              frame: CMSampleBuffer,
                              type: PipelineManager.MediaType,
                              register: () -> Void) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            register()
        }

        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }
}
