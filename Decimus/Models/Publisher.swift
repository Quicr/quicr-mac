import AVFoundation
import Foundation

class Publisher: QPublisherDelegateObjC {
    let codecFactory: EncoderFactory
    private unowned let publishDelegate: QPublishObjectDelegateObjC

    init(publishDelegate: QPublishObjectDelegateObjC, audioFormat: AVAudioFormat) {
        self.publishDelegate = publishDelegate
        self.codecFactory = .init(audioFormat: audioFormat)
    }

    func allocatePub(byNamespace quicrNamepace: String!) -> Any! {
        return Publication(namespace: quicrNamepace!, publishDelegate: publishDelegate, codecFactory: codecFactory)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
