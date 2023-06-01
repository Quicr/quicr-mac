import Foundation

class Subscriber: QSubscriberDelegateObjC {
    private unowned let player: FasterAVEngineAudioPlayer

    init(player: FasterAVEngineAudioPlayer) {
        self.player = player
    }

    func allocateSub(byNamespace quicrNamepace: String!) -> Any! {
        return Subscription(player: player)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
