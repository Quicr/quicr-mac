import Foundation

class Subscriber {
    private unowned let client: MediaClient
    private unowned let player: FasterAVEngineAudioPlayer
    private var subscriptions: [StreamIDType: Subscription] = [:]

    init(client: MediaClient, player: FasterAVEngineAudioPlayer) {
        self.client = client
        self.player = player
    }

    deinit {
        subscriptions.forEach { client.removeMediaSubscribeStream(mediaStreamId: $0.key) }
    }

    func allocateByStream(streamID: StreamIDType, mediaType: UInt8) -> Subscription {
        print(mediaType)
        let subscription: Subscription = mediaType == 1 ?
            AudioSubscription(client: client, player: player) :
            VideoSubscription(client: client)
        subscriptions[streamID] = subscription
        return subscription
    }

    func updateSubscriptionStreamID(streamID: StreamIDType) {
        if let subscription = subscriptions.removeValue(forKey: 0) {
            subscriptions[streamID] = subscription
        }
    }

    func removeByStream(streamID: StreamIDType) -> Bool {
        return subscriptions.removeValue(forKey: streamID) != nil
    }
}
