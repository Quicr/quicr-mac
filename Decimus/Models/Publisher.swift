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

    private var device: AVCaptureDevice?
    private var streamId: StreamIDType = 0
    private var encoder: Encoder?

    func prepareByStream(streamId: StreamIDType,
                         sourceId: SourceIDType,
                         qualityProfile: String) throws -> CodecConfig {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        self.device = AVCaptureDevice.init(uniqueID: sourceId)
        self.streamId = streamId

        do {
            try encoder = CodecFactory.shared.createEncoder(config) { data in
                let buffer = data.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let length: UInt32 = .init(data.buffer.count)
                let timestamp: UInt64 = .init(data.timestampMs)
                guard length > 0 else { return }

                switch config {
                case is AudioCodecConfig:
                    self.client.sendAudio(mediaStreamId: self.streamId,
                                           buffer: buffer,
                                           length: length,
                                           timestamp: timestamp)
                case is VideoCodecConfig:
                    self.client.sendVideoFrame(mediaStreamId: self.streamId,
                                                buffer: buffer,
                                                length: length,
                                                timestamp: timestamp,
                                                flag: false)
                default:
                    fatalError("Unrecognized codec config")
                }
            }

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
