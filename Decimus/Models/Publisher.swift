import Foundation
import AVFoundation

class Publisher {
    private unowned let client: MediaClient
    init(client: MediaClient) {
        self.client = client
    }

    deinit {
        self.client.removeMediaPublishStream(mediaStreamId: streamId)
    }

    private var streamId: StreamIDType = 0
    private unowned var device: AVCaptureDevice?
    private var encoder: Encoder?

    func prepareByStream(streamId: StreamIDType,
                         sourceId: SourceIDType,
                         qualityProfile: String,
                         encodeCallback: @escaping Encoder.EncodedBufferCallback) throws -> CodecConfig {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        do {
            try encoder = CodecFactory.shared.createEncoder(config, encodeCallback: encodeCallback)
            self.streamId = streamId
            print("[Publisher] Registered \(String(describing: config.codec)) to publish stream: \(streamId)")
        } catch {
            print("[Publisher] Failed to create encoder: \(error)")
            throw error
        }

        return config
    }

    func write(data: MediaBuffer) {
        guard let encoder = encoder else {
            fatalError("[Publisher:\(streamId)] No encoder for Publisher. Did you forget to prepare?")
        }
        encoder.write(data: data)
    }

    func write(sample: CMSampleBuffer) {
        guard let encoder = encoder else {
            fatalError("[Publisher:\(streamId)] No encoder for Publisher. Did you forget to prepare?")
        }
        encoder.write(data: sample.asMediaBuffer())
    }
}
