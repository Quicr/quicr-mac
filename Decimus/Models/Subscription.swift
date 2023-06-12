import Foundation
import AVFoundation

protocol Subscription: AnyObject {
    func prepare(streamID: StreamIDType, sourceID: SourceIDType, qualityProfile: String) throws
    var subscribedObject: SubscribeCallback {get}
}

class VideoSubscription: Subscription {
    // TODO: This is temporary before we change QMedia
    private class Weak {
        weak var value: VideoSubscription?
        init(_ value: VideoSubscription?) { self.value = value }
    }
    private static var weakStaticSources: [StreamIDType: Weak] = [:]
    // end TODO

    private unowned let client: MediaClient
    init(client: MediaClient) {
        self.client = client
    }

    deinit {
        self.client.removeMediaSubscribeStream(mediaStreamId: streamID)
        Self.weakStaticSources.removeValue(forKey: streamID)
    }

    private var streamID: StreamIDType = 0
    private var decoder: Decoder?

    func prepare(streamID: StreamIDType, sourceID: SourceIDType, qualityProfile: String) throws {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        self.streamID = streamID

        do {
            decoder = try CodecFactory.shared.createDecoder(identifier: streamID, config: config)

            // TODO: This is temporary before we change QMedia
            Self.weakStaticSources[streamID] = .init(self)

            print("[Subscriber] Subscribed to \(String(describing: config.codec)) stream: \(streamID)")
        } catch {
            print("[Subscriber] Failed to create decoder: \(error)")
            throw error
        }
    }

    let subscribedObject: SubscribeCallback = { streamId, _, _, data, length, timestamp in
        guard let subscriber = VideoSubscription.weakStaticSources[streamId]?.value else {
            fatalError("[Subscriber:\(streamId)] Failed to find instance for stream")
        }

        guard data != nil else {
            print("[Subscriber:\(streamId)] Data was nil")
            return
        }

        subscriber.write(data: .init(buffer: .init(start: data, count: Int(length)),
                                     timestampMs: UInt32(timestamp)))
    }

    private func write(data: MediaBuffer) {
        guard let decoder = decoder else {
            fatalError("[Subscriber:\(streamID)] No decoder for Subscriber. Did you forget to prepare?")
        }
        decoder.write(buffer: data)
    }
}
