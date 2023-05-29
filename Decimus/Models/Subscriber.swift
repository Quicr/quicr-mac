import Foundation

class Subscriber {
    private unowned let client: MediaClient
    private unowned let player: AudioPlayer
    private var subscriptions: [StreamIDType: Subscription] = [:]

    init(client: MediaClient, player: AudioPlayer) {
        self.client = client
        self.player = player
    }

    deinit {
        subscriptions.forEach { client.removeMediaSubscribeStream(mediaStreamId: $0.key) }
    }

    func allocateByStream(streamID: StreamIDType) -> Subscription {
        let subscription = Subscription(client: client, player: player)
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
