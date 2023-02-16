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

    let streamCallback: SubscribeCallback = { streamId, data, length, timestamp in
        guard let publisher = QMediaPubSub.streamIdMap[streamId] else {
            fatalError("Failed to find QMediaPubSub instance for stream: \(streamId))")
        }
        guard data != nil else { print("[QMediaPubSub] [Subscription \(streamId)] Data was nil"); return }
        print("[QMediaPubSub] [Subscription \(streamId)] Got \(length) bytes")
        publisher.pipeline!.decode(identifier: UInt32(streamId),
                                   data: data!,
                                   length: Int(length),
                                   timestamp: UInt32(timestamp))
    }

    func connect(config: CallConfig) {
        qMedia = .init(address: .init(string: config.address)!, port: config.port)

        // TODO: Where should the subscriptions go?
        let videoSubscription = qMedia!.addVideoStreamSubscribe(codec: .h264, callback: streamCallback)
        Self.streamIdMap[videoSubscription] = self
        pipeline!.registerDecoder(identifier: UInt32(videoSubscription), type: .video)
        let audioSubscription = qMedia!.addAudioStreamPublishIntent(codec: .opus)
        Self.streamIdMap[audioSubscription] = self
        pipeline!.registerDecoder(identifier: UInt32(audioSubscription), type: .audio)
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

    override func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer) {
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: frame, type: .video) {
            let size = frame.formatDescription!.dimensions
            let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: .h264)
            print("[QMediaPubSub] (\(identifier)) Video registered to publish stream: \(subscriptionId)")
            identifierMapping[identifier] = subscriptionId
            pipeline!.registerEncoder(identifier: identifier, width: size.width, height: size.height)
            identifierMapping[identifier] = qMedia!.addVideoStreamPublishIntent(codec: .h264)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: sample, type: .audio) {
            let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: .opus)
            print("[QMediaPubSub] (\(identifier)) Audio registered to publish stream: \(subscriptionId)")
            identifierMapping[identifier] = subscriptionId
            pipeline!.registerEncoder(identifier: identifier)
            identifierMapping[identifier] = qMedia!.addAudioStreamPublishIntent(codec: .opus)
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
