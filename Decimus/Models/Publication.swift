import Foundation
import AVFoundation

class Publication {
    private unowned let client: MediaClient

    private var notifier: NotificationCenter = .default

    init(client: MediaClient) {
        self.client = client
    }

    deinit {
        self.client.removeMediaPublishStream(mediaStreamId: streamID)
    }

    private(set) var device: AVCaptureDevice?
    private var streamID: StreamIDType = 0
    private var encoder: Encoder?

    func prepareByStream(streamID: StreamIDType,
                         sourceID: SourceIDType,
                         qualityProfile: String) throws {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        self.streamID = streamID
        self.device = AVCaptureDevice.init(uniqueID: sourceID)
        guard self.device != nil else {
            fatalError("[Publisher:\(self.streamID)] Failed to find device for publisher stream \(self.streamID)")
        }

        do {
            try encoder = CodecFactory.shared.createEncoder(config) { data in
                let buffer = data.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let length: UInt32 = .init(data.buffer.count)
                let timestamp: UInt64 = .init(data.timestampMs)
                guard length > 0 else { return }

                switch config {
                case is AudioCodecConfig:
                    self.client.sendAudio(mediaStreamId: self.streamID,
                                          buffer: buffer,
                                          length: length,
                                          timestamp: timestamp)
                case is VideoCodecConfig:
                    self.client.sendVideoFrame(mediaStreamId: self.streamID,
                                               buffer: buffer,
                                               length: length,
                                               timestamp: timestamp,
                                               flag: false)
                default:
                    fatalError("[Publisher:\(self.streamID)] Failed encode: Unrecognized codec config")
                }
            }

            print("[Publisher] Registered \(String(describing: config.codec)) to publish stream: \(streamID)")
        } catch {
            print("[Publisher] Failed to create encoder: \(error)")
            throw error
        }

        notifier.post(name: .deviceRegistered, object: device)
    }

    func write(data: MediaBuffer) {
        guard let encoder = encoder else {
            fatalError("[Publisher:\(streamID)] No encoder for Publisher. Did you forget to prepare?")
        }
        encoder.write(data: data)
    }

    func write(sample: CMSampleBuffer) {
        guard let encoder = encoder else {
            fatalError("[Publisher:\(streamID)] No encoder for Publisher. Did you forget to prepare?")
        }
        encoder.write(data: sample.asMediaBuffer())
    }
}

extension Notification.Name {
    static var deviceRegistered = Notification.Name("deviceRegistered")
}
