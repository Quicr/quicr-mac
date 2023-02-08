import SwiftUI
import CoreMedia

class QMediaPubSub: ApplicationModeBase {

    var qMedia: QMedia?

    let tempVideoId = 1
    let tempAudioId = 2

    override var root: AnyView {
        get { return .init(QMediaConfigCall(mode: self, callback: connect))}
        set { }
    }

    func connect(config: CallConfig) {
        qMedia = .init(address: .init(string: config.address)!, port: config.port)
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
                // TODO: Add IDR flag.
                qMedia!.sendVideoFrame(mediaStreamId: UInt64(0),
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

    override func encodeCameraFrame(frame: CMSampleBuffer) {
        encodeSample(identifier: 1, frame: frame, type: .video) {
            let size = frame.formatDescription!.dimensions
            let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: .h264)
            pipeline!.registerEncoder(identifier: UInt32(subscriptionId), width: size.width, height: size.height)

        }
    }

    override func encodeAudioSample(sample: CMSampleBuffer) {
        encodeSample(identifier: 2, frame: sample, type: .audio) {
            let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: .opus)
            pipeline!.registerEncoder(identifier: UInt32(subscriptionId))
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
